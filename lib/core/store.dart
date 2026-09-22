import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'paths.dart';

/// 一次抽取的结果。
class DrawResult {
  DrawResult({
    required this.names,
    required this.remaining,
    required this.listSize,
    required this.roundFinished,
  });

  final List<String> names;

  /// 不重复模式下：本轮还剩多少人没被抽到。
  /// 可重复模式下：等于名单总人数（无意义，仅用于展示）。
  final int remaining;

  final int listSize;

  /// 不重复模式下本轮是否已经抽完。
  final bool roundFinished;
}

/// 按权重随机挑一个。
///
/// * 权重 <= 0 的人**不会被返回**（这是「不参与抽取」的语义）；
/// * 所有人权重都 <= 0 时，退化为等概率（而不是崩溃或返回 null）。
Person? weightedPick(List<Person> candidates, math.Random rng) {
  if (candidates.isEmpty) return null;

  var total = 0.0;
  for (final person in candidates) {
    total += person.safeWeight;
  }
  if (total <= 0) {
    return candidates[rng.nextInt(candidates.length)];
  }

  var r = rng.nextDouble() * total;
  Person? lastPositive;
  for (final person in candidates) {
    final weight = person.safeWeight;
    // 必须显式跳过 0 权重的候选：否则当 r 恰好等于 0 时会把它抽出来
    if (weight <= 0) continue;
    lastPositive = person;
    r -= weight;
    if (r <= 0) return person;
  }
  return lastPositive ?? candidates.last;
}

/// 由「已抽走的名单」和「当前名单」推导出本轮还剩谁没被抽。
///
/// 纯函数，方便单元测试。**这是不重复模式的核心状态**：
/// 只记录谁被抽走了，池子永远现算，因此不会出现
/// 「给名单加个人，结果已经抽走的人又冒回池子」这种 bug。
///
/// 规则：
/// * 名单里的人，减去已抽走的同名次数，就是剩余；
/// * 结果按名单原始顺序排列；
/// * 已抽走但后来被移出名单的人（drawn 里的过期条目）会被自然忽略；
/// * 重名按出现次数分别计算。
List<String> derivePoolNames(List<String> drawn, List<Person> people) {
  final remaining = <String, int>{};
  for (final person in people) {
    remaining[person.name] = (remaining[person.name] ?? 0) + 1;
  }

  for (final name in drawn) {
    final count = remaining[name] ?? 0;
    if (count > 0) {
      remaining[name] = count - 1;
    }
  }

  final pool = <String>[];
  for (final person in people) {
    final count = remaining[person.name] ?? 0;
    if (count > 0) {
      pool.add(person.name);
      remaining[person.name] = count - 1;
    }
  }
  return pool;
}

/// 全部应用状态 + 磁盘读写。
///
/// 落盘的四个文件都在 `RandomPickerData/` 下：
///   config.json  设置
///   lists.json   所有名单
///   state.json   不重复模式「已被抽走的人」
///   history.json 抽取历史
class DataStore extends ChangeNotifier {
  AppConfig config = AppConfig();
  final List<NameList> lists = <NameList>[];
  final List<DrawRecord> history = <DrawRecord>[];

  /// listId -> 本轮已经被抽走的人名（允许重名，所以用 List 不用 Set）。
  final Map<String, List<String>> _drawn = <String, List<String>>{};

  final math.Random _rng = math.Random();

  bool loaded = false;
  String dataPath = '';
  String? loadError;

  /// 是否落盘。widget 测试里必须设为 false：
  /// `testWidgets` 运行在 fake async 环境，真实文件 I/O 的 Future 不会完成，
  /// 会让「开始抽取」这类 await 了磁盘写入的操作永远停在半路。
  /// 持久化本身的正确性由 test/logic_test.dart 用真实 I/O 覆盖。
  bool persist = true;

  // ------------------------------------------------------------------ 读取

  NameList? get currentList {
    final id = config.currentListId;
    if (id != null) {
      for (final list in lists) {
        if (list.id == id) return list;
      }
    }
    return lists.isEmpty ? null : lists.first;
  }

  Future<void> load() async {
    try {
      final dir = await AppPaths.dataDir();
      dataPath = dir.path;

      final cfg = await _readMap(File(p.join(dir.path, 'config.json')));
      config = cfg == null ? AppConfig() : AppConfig.fromJson(cfg);

      final listsJson = await _readMap(File(p.join(dir.path, 'lists.json')));
      lists.clear();
      final rawLists = listsJson?['lists'];
      if (rawLists is List) {
        for (final item in rawLists) {
          if (item is Map) {
            lists.add(NameList.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }
      if (lists.isEmpty) {
        // 首次运行给一份示例，用户随手就能试；不想要直接删掉即可。
        lists.add(NameList(
          id: NameList.newId(),
          name: '示例名单',
          people: const ['张三', '李四', '王五', '赵六', '钱七']
              .map((e) => Person(name: e))
              .toList(),
        ));
      }

      final stateJson = await _readMap(File(p.join(dir.path, 'state.json')));
      _drawn.clear();
      final rawDrawn = stateJson?['drawn'];
      if (rawDrawn is Map) {
        rawDrawn.forEach((key, value) {
          if (value is List) {
            _drawn[key.toString()] = value.map((e) => e.toString()).toList();
          }
        });
      }

      final historyJson = await _readMap(File(p.join(dir.path, 'history.json')));
      history.clear();
      final rawRecords = historyJson?['records'];
      if (rawRecords is List) {
        for (final item in rawRecords) {
          if (item is Map) {
            history.add(DrawRecord.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      if (config.currentListId == null ||
          !lists.any((l) => l.id == config.currentListId)) {
        config.currentListId = lists.first.id;
      }
      for (final list in lists) {
        _pruneDrawn(list);
      }

      loaded = true;
      await saveAll();
    } catch (e) {
      loadError = '$e';
      loaded = true;
      if (lists.isEmpty) {
        lists.add(NameList(
          id: NameList.newId(),
          name: '示例名单',
          people: const ['张三', '李四', '王五']
              .map((e) => Person(name: e))
              .toList(),
        ));
      }
      config.currentListId ??= lists.first.id;
    }
  }

  // ------------------------------------------------------------ 不重复池管理

  /// 权重 > 0 的人算「参与本轮抽取」。所有人权重都 <= 0 时退化为全员参与。
  List<Person> eligiblePeople(NameList list) {
    final positive = list.people.where((e) => e.safeWeight > 0).toList();
    return positive.isEmpty ? List<Person>.from(list.people) : positive;
  }

  /// 本轮参与抽取的人数（权重为 0 的人不算）。
  int eligibleCount(NameList list) => eligiblePeople(list).length;

  /// 本轮还没被抽到的人（按名单顺序）。每次现算，永远是准的。
  List<String> poolOf(NameList list) =>
      derivePoolNames(_drawn[list.id] ?? const <String>[], eligiblePeople(list));

  /// 注意：必须用推导出的池子长度，不能直接用 `_drawn` 的条数 ——
  /// 名单缩小后 `_drawn` 里可能残留过期条目，会让计数偏小。
  int remaining(NameList list) => poolOf(list).length;

  int drawnCount(NameList list) => eligibleCount(list) - remaining(list);

  /// 清掉 `_drawn` 里已经不在名单上的过期条目，保持 state.json 干净。
  /// 副作用是「删掉某人再加回来」时这个人会重新回到池子 —— 符合直觉。
  void _pruneDrawn(NameList list) {
    final drawn = _drawn[list.id];
    if (drawn == null || drawn.isEmpty) return;

    final allowed = <String, int>{};
    for (final person in list.people) {
      allowed[person.name] = (allowed[person.name] ?? 0) + 1;
    }

    final used = <String, int>{};
    final kept = <String>[];
    for (final name in drawn) {
      final max = allowed[name] ?? 0;
      final have = used[name] ?? 0;
      if (have < max) {
        kept.add(name);
        used[name] = have + 1;
      }
    }
    _drawn[list.id] = kept;
  }

  // ------------------------------------------------------------------ 抽取

  Future<DrawResult> draw({
    required NameList list,
    required DrawMode mode,
    required int count,
    required bool allowDuplicateInBatch,
  }) async {
    final budget = count < 1 ? 1 : count;
    final picked = <String>[];

    if (mode == DrawMode.noRepeat) {
      final eligible = eligiblePeople(list);

      // 一次性建好 名字 -> Person 索引，避免在循环里反复线性查找
      final byName = <String, Person>{};
      for (final person in eligible) {
        byName.putIfAbsent(person.name, () => person);
      }

      // 候选池 = 参与抽取的人 - 已被抽走的人
      final candidates = derivePoolNames(
        _drawn[list.id] ?? const <String>[],
        eligible,
      ).map((name) => byName[name] ?? Person(name: name)).toList();

      final n = math.min(budget, candidates.length);
      for (var i = 0; i < n; i++) {
        final chosen = weightedPick(candidates, _rng);
        if (chosen == null) break;
        picked.add(chosen.name);
        candidates.remove(chosen); // 按对象身份删除，重名也只会删掉一个
      }

      if (picked.isNotEmpty) {
        _drawn.putIfAbsent(list.id, () => <String>[]).addAll(picked);
      }
    } else {
      // 权重为 0 的人不参与抽取
      final source = eligiblePeople(list);

      if (allowDuplicateInBatch) {
        for (var i = 0; i < budget; i++) {
          final chosen = weightedPick(source, _rng);
          if (chosen == null) break;
          picked.add(chosen.name);
        }
      } else {
        // 同一次批量抽取内不重复，下一次抽取时这些人自动「放回」
        final working = List<Person>.from(source);
        final n = math.min(budget, working.length);
        for (var i = 0; i < n; i++) {
          final chosen = weightedPick(working, _rng);
          if (chosen == null) break;
          picked.add(chosen.name);
          working.remove(chosen); // Person 没有重写 ==，这里按对象身份删除
        }
      }
    }

    final remainingCount = remaining(list);
    final totalEligible = eligibleCount(list);

    final result = DrawResult(
      names: picked,
      remaining: remainingCount,
      listSize: totalEligible,
      roundFinished: mode == DrawMode.noRepeat &&
          remainingCount == 0 &&
          totalEligible > 0,
    );

    if (picked.isNotEmpty) {
      history.insert(
        0,
        DrawRecord(
          time: DateTime.now(),
          listName: list.name,
          mode: mode,
          names: List<String>.from(picked),
        ),
      );
      if (history.length > 500) {
        history.removeRange(500, history.length);
      }
      await saveHistory();
    }
    if (mode == DrawMode.noRepeat) {
      await saveState();
    }

    notifyListeners();
    return result;
  }

  // ---------------------------------------------------------------- 名单操作

  Future<void> selectList(String id) async {
    config.currentListId = id;
    notifyListeners();
    await saveConfig();
  }

  Future<NameList> createList(String name, List<Person> people) async {
    final list = NameList(id: NameList.newId(), name: name, people: people);
    lists.add(list);
    config.currentListId = list.id;
    _drawn[list.id] = <String>[];
    notifyListeners();
    await saveLists();
    await saveConfig();
    await saveState();
    return list;
  }

  /// 改名单不会丢本轮进度：已经抽走的人不会被放回，新增的人会进池子。
  Future<void> updateList(
    NameList list, {
    String? name,
    List<Person>? people,
  }) async {
    if (name != null && name.trim().isNotEmpty) list.name = name.trim();
    if (people != null) list.people = people;
    _pruneDrawn(list);
    notifyListeners();
    await saveLists();
    await saveState();
  }

  Future<void> deleteList(NameList list) async {
    if (lists.length <= 1) return;
    lists.remove(list);
    _drawn.remove(list.id);
    if (config.currentListId == list.id) {
      config.currentListId = lists.first.id;
    }
    notifyListeners();
    await saveLists();
    await saveConfig();
    await saveState();
  }

  Future<void> duplicateList(NameList list) async {
    final copy = NameList(
      id: NameList.newId(),
      name: '${list.name} 副本',
      people: list.people
          .map((e) => Person(name: e.name, weight: e.weight, note: e.note))
          .toList(),
    );
    lists.add(copy);
    config.currentListId = copy.id;
    _drawn[copy.id] = <String>[];
    notifyListeners();
    await saveLists();
    await saveConfig();
    await saveState();
  }

  /// 开始新一轮：清空已抽记录，所有人回到池子。
  Future<void> resetRound(NameList list) async {
    _drawn[list.id] = <String>[];
    notifyListeners();
    await saveState();
  }

  Future<void> clearHistory() async {
    history.clear();
    notifyListeners();
    await saveHistory();
  }

  // ------------------------------------------------------------------ 设置

  Future<void> setMode(DrawMode mode) async {
    config.mode = mode;
    notifyListeners();
    await saveConfig();
  }

  Future<void> setBatchCount(int count) async {
    config.batchCount = count < 1 ? 1 : count;
    notifyListeners();
    await saveConfig();
  }

  Future<void> setTheme(String themeId) async {
    config.themeId = themeId;
    notifyListeners();
    await saveConfig();
  }

  Future<void> updateConfig(AppConfig next) async {
    config = next;
    notifyListeners();
    await saveConfig();
  }

  // -------------------------------------------------------------- 文件读写

  Future<Map<String, dynamic>?> _readMap(File file) async {
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('读取 ${file.path} 失败：$e');
    }
    return null;
  }

  /// 先写临时文件再改名，避免断电 / 崩溃把原文件写坏。
  Future<void> _writeMap(File file, Map<String, dynamic> data) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  /// 落盘开关的唯一入口：`persist == false` 时直接跳过。
  Future<void> _save(String name, Map<String, dynamic> data) async {
    if (!persist) return;
    await _writeMap(await AppPaths.dataFile(name), data);
  }

  Future<void> saveConfig() => _save('config.json', config.toJson());

  Future<void> saveLists() => _save(
        'lists.json',
        {'lists': lists.map((e) => e.toJson()).toList()},
      );

  Future<void> saveState() => _save('state.json', {'drawn': _drawn});

  Future<void> saveHistory() => _save(
        'history.json',
        {'records': history.map((e) => e.toJson()).toList()},
      );

  Future<void> saveAll() async {
    await saveConfig();
    await saveLists();
    await saveState();
    await saveHistory();
  }
}
