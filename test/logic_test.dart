import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:random_picker/core/importer.dart';
import 'package:random_picker/core/models.dart';
import 'package:random_picker/core/paths.dart';
import 'package:random_picker/core/store.dart';
import 'package:random_picker/core/updater.dart';

void main() {
  // ------------------------------------------------------------ 版本号比较

  group('compareVersions', () {
    test('基本比较', () {
      expect(compareVersions('1.0.1', '1.0.0'), 1);
      expect(compareVersions('1.0.0', '1.0.1'), -1);
      expect(compareVersions('1.0.0', '1.0.0'), 0);
    });

    test('忽略 v 前缀与预发布后缀', () {
      expect(compareVersions('v1.2.0', '1.1.9'), 1);
      expect(compareVersions('1.2.0-beta.1', '1.2.0'), 0);
      expect(compareVersions('V2.0', '1.9.9'), 1);
    });

    test('位数不足补零，且按数字而不是字符串比较', () {
      expect(compareVersions('1.1', '1.0.9'), 1);
      expect(compareVersions('1', '1.0.0'), 0);
      expect(compareVersions('1.10.0', '1.9.0'), 1); // 字符串比较会判错
      expect(compareVersions('2.0.0', '10.0.0'), -1);
    });
  });

  group('normalizeRepo', () {
    test('各种写法都归一成 owner/repo', () {
      expect(normalizeRepo('zhangsan/random-picker'), 'zhangsan/random-picker');
      expect(
        normalizeRepo('https://github.com/zhangsan/random-picker'),
        'zhangsan/random-picker',
      );
      expect(
        normalizeRepo('https://github.com/zhangsan/random-picker.git'),
        'zhangsan/random-picker',
      );
      expect(
        normalizeRepo('  zhangsan/random-picker/  '),
        'zhangsan/random-picker',
      );
      expect(
        normalizeRepo('https://github.com/zhangsan/random-picker/releases'),
        'zhangsan/random-picker',
      );
      expect(
        normalizeRepo('git@github.com:zhangsan/random-picker.git'),
        'zhangsan/random-picker',
      );
    });
  });

  // ------------------------------------------------------------ txt 导入

  group('parseTextImport', () {
    test('一行一个名字，忽略空行和注释', () {
      final r = parseTextImport('张三\n\n# 注释\n李四\n// 也是注释\n王五', '测试');
      expect(r.people.map((e) => e.name).toList(), ['张三', '李四', '王五']);
      expect(r.people.every((e) => e.weight == 1.0), isTrue);
      expect(r.name, '测试');
      // 前后空格会被去掉
      expect(parseTextImport('  赵六  ', 'x').people.single.name, '赵六');
    });

    test('支持 名字,权重', () {
      final r = parseTextImport('张三,3\n李四', '测试');
      expect(r.people[0].name, '张三');
      expect(r.people[0].weight, 3.0);
      expect(r.people[1].weight, 1.0);
    });

    test('名字里带逗号但后面不是数字时，整行当作名字', () {
      final r = parseTextImport('张三,李四', '测试');
      expect(r.people.length, 1);
      expect(r.people.single.name, '张三,李四');
    });

    test('负数或非法权重按 0 处理（永不被抽中）', () {
      final r = parseTextImport('张三,-5', '测试');
      expect(r.people.single.weight, 0.0);
      expect(r.people.single.safeWeight, 0.0);
    });

    test('空内容：默认抛 ImportException，lenient 时返回空列表', () {
      expect(() => parseTextImport('\n\n', '测试'), throwsA(isA<ImportException>()));
      expect(parseTextImport('\n\n', '测试', lenient: true).people, isEmpty);
    });
  });

  // ----------------------------------------------------------- json 导入

  group('parseJsonImport', () {
    test('字符串数组', () {
      final r = parseJsonImport('["张三","李四"]', '兜底名');
      expect(r.people.map((e) => e.name).toList(), ['张三', '李四']);
      expect(r.name, '兜底名');
    });

    test('对象带 name 和 people，元素可混用字符串与对象', () {
      final r = parseJsonImport(
        '{"name":"三班","people":["张三",{"name":"李四","weight":2}]}',
        '兜底',
      );
      expect(r.name, '三班');
      expect(r.people.length, 2);
      expect(r.people[1].weight, 2.0);
    });

    test('listName / names 字段与 note 字段', () {
      final r = parseJsonImport(
        '{"listName":"四班","names":[{"name":"王五","note":"班长"}]}',
        '兜底',
      );
      expect(r.name, '四班');
      expect(r.people.single.name, '王五');
      expect(r.people.single.note, '班长');
    });

    test('非法 JSON 与缺少数组都抛 ImportException', () {
      expect(() => parseJsonImport('{oops', '兜底'), throwsA(isA<ImportException>()));
      expect(() => parseJsonImport('{"foo":1}', '兜底'), throwsA(isA<ImportException>()));
      expect(() => parseJsonImport('[]', '兜底'), throwsA(isA<ImportException>()));
    });
  });

  // -------------------------------------------------- 发布附件选择

  group('pickAssetUrl（从 Release 附件里挑下载包）', () {
    List<dynamic> assetsOf(List<String> names) => names
        .map((n) => <String, dynamic>{
              'name': n,
              'browser_download_url': 'https://example.com/$n',
            })
        .toList();

    test('【回归】不会挑中排在更前面的 arm64 包', () {
      // 这不是编的：真实数据里 microsoft/PowerToys 的 assets 中
      // arm64 就排在 x64 前面，旧实现只取「第一个后缀匹配项」，会挑错架构。
      final assets = assetsOf([
        'PowerToysSetup-0.101.0-arm64.exe',
        'PowerToysSetup-0.101.0-x64.exe',
      ]);
      expect(
        pickAssetUrl(assets, ''),
        'https://example.com/PowerToysSetup-0.101.0-x64.exe',
      );
    });

    test('arm 与 x64 同时出现时优先 x64', () {
      final assets = assetsOf(['app-win-arm64.zip', 'app-win-x64.zip']);
      expect(pickAssetUrl(assets, '.zip'), 'https://example.com/app-win-x64.zip');
    });

    test('后缀限定生效：要 .exe 就不会给 .zip', () {
      final assets = assetsOf(['app-x64.zip', 'app-x64.exe']);
      expect(pickAssetUrl(assets, '.exe'), 'https://example.com/app-x64.exe');
      expect(pickAssetUrl(assets, '.zip'), 'https://example.com/app-x64.zip');
    });

    test('名字里没有 x64/win 标识时，退回第一个后缀匹配项', () {
      final assets = assetsOf(['release-a.zip', 'release-b.zip']);
      expect(pickAssetUrl(assets, '.zip'), 'https://example.com/release-a.zip');
    });

    test('后缀全都匹配不上时，兜底取第一个附件', () {
      final assets = assetsOf(['a.tar.gz', 'b.zip']);
      expect(pickAssetUrl(assets, '.exe'), 'https://example.com/a.tar.gz');
    });

    test('空列表 / null 都返回 null，不抛异常', () {
      expect(pickAssetUrl(<dynamic>[], ''), isNull);
      expect(pickAssetUrl(null, ''), isNull);
    });

    test('附件没有下载地址时返回 null', () {
      final assets = <dynamic>[
        <String, dynamic>{'name': 'x-x64.zip', 'browser_download_url': ''},
      ];
      expect(pickAssetUrl(assets, ''), isNull);
    });

    test('忽略结构不对的附件项', () {
      final assets = <dynamic>[
        'not-a-map',
        42,
        null,
        <String, dynamic>{
          'name': 'ok-x64.zip',
          'browser_download_url': 'https://example.com/ok-x64.zip',
        },
      ];
      expect(pickAssetUrl(assets, ''), 'https://example.com/ok-x64.zip');
    });
  });

  // -------------------------------------------------------- 池子推导算法

  group('derivePoolNames', () {
    List<Person> peopleOf(List<String> names) =>
        names.map((e) => Person(name: e)).toList();

    test('没人被抽走时，池子就是完整名单（顺序不变）', () {
      expect(derivePoolNames(<String>[], peopleOf(['a', 'b', 'c'])), ['a', 'b', 'c']);
    });

    test('抽走的人不在池子里，其余保持名单顺序', () {
      expect(derivePoolNames(['b'], peopleOf(['a', 'b', 'c'])), ['a', 'c']);
      expect(derivePoolNames(['a'], peopleOf(['a', 'b', 'c'])), ['b', 'c']);
    });

    test('抽完一轮后池子为空', () {
      expect(derivePoolNames(['a', 'b', 'c'], peopleOf(['a', 'b', 'c'])), isEmpty);
    });

    test('已抽走的人被移出名单后，过期的 drawn 条目会被忽略', () {
      expect(derivePoolNames(['b'], peopleOf(['a', 'c'])), ['a', 'c']);
      expect(derivePoolNames(['x', 'y'], peopleOf(['a', 'b'])), ['a', 'b']);
    });

    test('重名按出现次数分别计算', () {
      expect(derivePoolNames(<String>[], peopleOf(['a', 'a', 'a'])), ['a', 'a', 'a']);
      expect(derivePoolNames(['a'], peopleOf(['a', 'a', 'a'])), ['a', 'a']);
      expect(derivePoolNames(['a', 'a'], peopleOf(['a', 'a', 'a'])), ['a']);
      expect(derivePoolNames(['a', 'a', 'a'], peopleOf(['a', 'a', 'a'])), isEmpty);
    });

    test('【回归】给名单加人不会让已抽走的人复活', () {
      // 曾经的 bug：算法只看池子里剩谁，加人时会把已抽走的重新补回来
      final people = peopleOf(['p1', 'p2', 'p3', 'p4', 'p5']);
      final afterDraw = derivePoolNames(['p1', 'p2'], people);
      expect(afterDraw, ['p3', 'p4', 'p5']);

      final grown = derivePoolNames(['p1', 'p2'], peopleOf(['p1', 'p2', 'p3', 'p4', 'p5', 'p6']));
      expect(grown, ['p3', 'p4', 'p5', 'p6']);
      expect(grown.contains('p1'), isFalse);
      expect(grown.contains('p2'), isFalse);
    });
  });

  // ------------------------------------------------------------ 权重抽取

  group('weightedPick', () {
    test('权重为 0 的人永远不会被抽中', () {
      final candidates = [
        Person(name: 'a', weight: 0),
        Person(name: 'b', weight: 1),
      ];
      final rng = Random(42);
      for (var i = 0; i < 500; i++) {
        expect(weightedPick(candidates, rng)!.name, 'b');
      }
    });

    test('权重全为 0 时退化为等概率，而不是崩溃或返回 null', () {
      final candidates = [
        Person(name: 'a', weight: 0),
        Person(name: 'b', weight: 0),
      ];
      final rng = Random(1);
      final picked = <String>{};
      for (var i = 0; i < 300; i++) {
        picked.add(weightedPick(candidates, rng)!.name);
      }
      expect(picked, {'a', 'b'});
    });

    test('高权重被抽中的次数明显更多', () {
      final candidates = [
        Person(name: 'low', weight: 1),
        Person(name: 'high', weight: 9),
      ];
      final rng = Random(7);
      var high = 0;
      for (var i = 0; i < 2000; i++) {
        if (weightedPick(candidates, rng)!.name == 'high') high++;
      }
      expect(high, greaterThan(1500)); // 期望约 1800
    });

    test('空列表返回 null', () {
      expect(weightedPick(<Person>[], Random(1)), isNull);
    });
  });

  // ------------------------------------------------------- DataStore 行为

  group('DataStore 抽取行为', () {
    late Directory tmp;
    late DataStore store;

    List<Person> peopleOf(List<String> names) =>
        names.map((e) => Person(name: e)).toList();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('random_picker_test_');
      AppPaths.overrideDataDirForTesting(tmp);
      store = DataStore();
      await store.createList('测试名单', peopleOf(['p1', 'p2', 'p3', 'p4', 'p5']));
    });

    tearDown(() async {
      AppPaths.resetForTesting();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('不重复模式：抽满一轮互不相同，之后本轮结束', () async {
      final list = store.currentList!;
      final picked = <String>[];
      for (var i = 0; i < 5; i++) {
        final r = await store.draw(
          list: list,
          mode: DrawMode.noRepeat,
          count: 1,
          allowDuplicateInBatch: false,
        );
        picked.addAll(r.names);
      }
      expect(picked.length, 5);
      expect(picked.toSet().length, 5, reason: '一轮内不应该抽到重复的人');
      expect(store.remaining(list), 0);

      final afterDone = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 1,
        allowDuplicateInBatch: false,
      );
      expect(afterDone.names, isEmpty);
      expect(afterDone.roundFinished, isTrue);
    });

    test('不重复模式：一次抽 3 个，剩余 2 且互不相同', () async {
      final list = store.currentList!;
      final r = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 3,
        allowDuplicateInBatch: false,
      );
      expect(r.names.length, 3);
      expect(r.names.toSet().length, 3);
      expect(store.remaining(list), 2);
      expect(store.drawnCount(list), 3);
    });

    test('不重复模式：要抽的人数超过剩余时，只抽剩下的', () async {
      final list = store.currentList!;
      final r = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 99,
        allowDuplicateInBatch: false,
      );
      expect(r.names.length, 5);
      expect(r.roundFinished, isTrue);
    });

    test('不重复模式：resetRound 后全部回到池子', () async {
      final list = store.currentList!;
      await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 99,
        allowDuplicateInBatch: false,
      );
      expect(store.remaining(list), 0);

      await store.resetRound(list);
      expect(store.remaining(list), 5);
      expect(store.drawnCount(list), 0);
    });

    test('不重复模式：中途给名单加人，进度不丢且已抽的人不复活', () async {
      final list = store.currentList!;
      final first = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 2,
        allowDuplicateInBatch: false,
      );
      final alreadyDrawn = first.names;
      expect(store.remaining(list), 3);

      await store.updateList(list, people: peopleOf(['p1', 'p2', 'p3', 'p4', 'p5', 'p6']));

      // 只多出 p6 这一个新人，已抽走的两个不会回到池子里
      expect(store.remaining(list), 4);
      expect(store.drawnCount(list), 2);
      final pool = store.poolOf(list);
      for (final name in alreadyDrawn) {
        expect(pool.contains(name), isFalse, reason: '$name 已经抽过了，不该复活');
      }
      expect(pool.contains('p6'), isTrue);
    });

    test('不重复模式：从名单里删掉一个没被抽中的人，池子同步收缩', () async {
      final list = store.currentList!;
      final first = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 1,
        allowDuplicateInBatch: false,
      );
      final drawnName = first.names.single;
      expect(store.remaining(list), 4);

      // 刻意删掉一个「没被抽中」的人：新名单 4 人，而且包含刚被抽中的那个。
      // （一开始这里写错了，用 survivors.sublist(...) 多删了一个，
      //   把刚抽中的人一起删掉了，导致期望值和实际语义对不上。）
      final full = <String>['p1', 'p2', 'p3', 'p4', 'p5'];
      final victim = full.firstWhere((n) => n != drawnName);
      final narrowed = full.where((n) => n != victim).toList();

      await store.updateList(list, people: peopleOf(narrowed));

      expect(narrowed.contains(victim), isFalse, reason: '被删的人不该还在名单里');
      expect(narrowed.contains(drawnName), isTrue, reason: '刚被抽中的人应该还在名单里');
      expect(store.remaining(list), 3);
      expect(store.drawnCount(list), 1);
      expect(store.poolOf(list).contains(drawnName), isFalse);
    });

    test('不重复模式：删掉的人如果正好是已抽中的，进度按剩下的重新算', () async {
      final list = store.currentList!;
      final first = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 1,
        allowDuplicateInBatch: false,
      );
      final drawnName = first.names.single;

      // 把这个已被抽中的人整个删掉，名单变成 4 个人、0 个已抽
      final others = <String>['p1', 'p2', 'p3', 'p4', 'p5']
          .where((n) => n != drawnName)
          .toList();
      await store.updateList(list, people: peopleOf(others));

      expect(store.drawnCount(list), 0);
      expect(store.remaining(list), 4);
      expect(store.poolOf(list), others);
    });

    test('可重复模式：一次抽多人默认互不相同', () async {
      final list = store.currentList!;
      final r = await store.draw(
        list: list,
        mode: DrawMode.repeat,
        count: 5,
        allowDuplicateInBatch: false,
      );
      expect(r.names.length, 5);
      expect(r.names.toSet().length, 5);
    });

    test('可重复模式：允许重复时能抽到同一个人，且池子不受影响', () async {
      final list = store.currentList!;
      final r = await store.draw(
        list: list,
        mode: DrawMode.repeat,
        count: 40,
        allowDuplicateInBatch: true,
      );
      expect(r.names.length, 40);
      expect(r.names.toSet().length, lessThanOrEqualTo(5));
      expect(store.remaining(list), 5);
    });

    test('抽取会写入历史并且落盘', () async {
      final list = store.currentList!;
      await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 2,
        allowDuplicateInBatch: false,
      );

      expect(store.history.length, 1);
      expect(store.history.first.names.length, 2);

      expect(await File(p.join(tmp.path, 'lists.json')).exists(), isTrue);
      expect(await File(p.join(tmp.path, 'state.json')).exists(), isTrue);
      expect(await File(p.join(tmp.path, 'history.json')).exists(), isTrue);
      expect(await File(p.join(tmp.path, 'config.json')).exists(), isTrue);
    });

    test('权重为 0 的人是「不参与抽取」，不占池子也不会被抽到', () async {
      await store.createList('有权重', [
        Person(name: 'never', weight: 0),
        Person(name: 'always', weight: 5),
      ]);
      final list = store.currentList!;
      expect(store.eligibleCount(list), 1);
      expect(store.poolOf(list), ['always']);

      final r = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: 2,
        allowDuplicateInBatch: false,
      );
      expect(r.names, ['always']);
      // 0 权重的人不该把这一轮永远卡在「还剩 1 个」
      expect(r.roundFinished, isTrue);
    });
  });

  // -------------------------------------------------------- 配置序列化

  group('序列化往返', () {
    test('AppConfig 往返一致', () {
      final config = AppConfig(
        githubRepo: 'a/b',
        updateBranch: 'dev',
        autoCheckUpdate: false,
        mode: DrawMode.repeat,
        batchCount: 7,
        allowDuplicateInBatch: true,
        animation: false,
        currentListId: 'xyz',
      );
      final back = AppConfig.fromJson(config.toJson());
      expect(back.githubRepo, 'a/b');
      expect(back.updateBranch, 'dev');
      expect(back.autoCheckUpdate, isFalse);
      expect(back.mode, DrawMode.repeat);
      expect(back.batchCount, 7);
      expect(back.allowDuplicateInBatch, isTrue);
      expect(back.animation, isFalse);
      expect(back.currentListId, 'xyz');
    });

    test('AppConfig 缺字段时用安全默认值', () {
      final back = AppConfig.fromJson(<String, dynamic>{});
      expect(back.mode, DrawMode.noRepeat);
      expect(back.batchCount, 1);
      expect(back.autoCheckUpdate, isTrue);
      expect(back.animation, isTrue);
      expect(back.currentListId, isNull);
    });

    test('NameList 往返一致，且容忍字符串数组写法', () {
      final list = NameList(
        id: 'id1',
        name: '一班',
        people: [Person(name: '张三'), Person(name: '李四', weight: 3)],
      );
      final back = NameList.fromJson(list.toJson());
      expect(back.id, 'id1');
      expect(back.name, '一班');
      expect(back.people.length, 2);
      expect(back.people[1].weight, 3.0);

      final loose = NameList.fromJson(<String, dynamic>{'name': '二班', 'names': ['甲', '乙']});
      expect(loose.people.map((e) => e.name).toList(), ['甲', '乙']);
      expect(loose.id.isNotEmpty, isTrue);
    });

    test('缺少 weight 字段时默认 1，NaN 之类被当成 0', () {
      expect(Person.fromJson(<String, dynamic>{'name': 'a'}).weight, 1.0);
      expect(Person.fromJson(<String, dynamic>{'name': 'a', 'weight': 'x'}).weight, 1.0);
      expect(Person.fromJson(<String, dynamic>{'name': 'a', 'weight': -3}).safeWeight, 0.0);
    });
  });

  // -------------------------------------------------- 真实文件导入

  group('importFromFile（读真实文件）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rp_import_');
    });

    tearDown(() async {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<String> writeBytes(String name, List<int> bytes) async {
      final file = File(p.join(tmp.path, name));
      await file.writeAsBytes(bytes);
      return file.path;
    }

    Future<String> writeText(String name, String text) =>
        writeBytes(name, utf8.encode(text));

    test('读 UTF-8 的 txt，名字与权重都对', () async {
      final path = await writeText('一班.txt', '张三\n李四,2\n\n# 注释\n王五\n');
      final result = await importFromFile(path);
      expect(result.name, '一班');
      expect(result.people.map((e) => e.name).toList(), ['张三', '李四', '王五']);
      expect(result.people[1].weight, 2.0);
    });

    test('容忍带 BOM 的 UTF-8（记事本另存为可能加 BOM）', () async {
      final path = await writeBytes(
        'bom.txt',
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('张三\n李四\n')],
      );
      final result = await importFromFile(path);
      // BOM 必须被剥掉，否则第一个名字会变成 "\uFEFF张三"
      expect(result.people.first.name, '张三');
      expect(result.people.first.name.startsWith('\uFEFF'), isFalse);
    });

    test('读 JSON，名单名取自 JSON', () async {
      final path = await writeText(
        '三班.json',
        '{"name":"三班","people":["甲",{"name":"乙","weight":2}]}',
      );
      final result = await importFromFile(path);
      expect(result.name, '三班');
      expect(result.people.length, 2);
      expect(result.people[1].weight, 2.0);
    });

    test('GBK 文件给出可操作的提示，而不是塞一堆乱码', () async {
      // 「张三\n」的 GBK 编码：D5 C5 C8 FD 0A
      final path = await writeBytes('gbk.txt', <int>[0xD5, 0xC5, 0xC8, 0xFD, 0x0A]);
      await expectLater(
        importFromFile(path),
        throwsA(isA<ImportException>().having(
          (e) => e.message,
          'message',
          allOf(contains('UTF-8'), contains('另存为')),
        )),
      );
    });

    test('空文件给出提示', () async {
      final path = await writeBytes('empty.txt', <int>[]);
      await expectLater(importFromFile(path), throwsA(isA<ImportException>()));
    });

    test('文件不存在给出提示，不崩', () async {
      await expectLater(
        importFromFile(p.join(tmp.path, '根本不存在.txt')),
        throwsA(isA<ImportException>()),
      );
    });
  });

  // -------------------------------------------- 跨重启持久化（读回来）

  group('持久化：load() 能把写出去的东西读回来', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rp_persist_');
      AppPaths.overrideDataDirForTesting(tmp);
    });

    tearDown(() async {
      AppPaths.resetForTesting();
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('名单、进行中的抽取进度、设置、历史 全部能跨重启恢复', () async {
      // ---- 第一次运行 ----
      final first = DataStore();
      await first.createList(
        '持久化测试',
        ['a', 'b', 'c', 'd'].map((e) => Person(name: e)).toList(),
      );
      first.config.githubRepo = 'someone/some-repo';
      first.config.mode = DrawMode.repeat;
      first.config.batchCount = 4;
      first.config.animation = false;
      await first.saveConfig();

      final sourceList = first.currentList!;
      await first.draw(
        list: sourceList,
        mode: DrawMode.noRepeat,
        count: 2,
        allowDuplicateInBatch: false,
      );
      final drawnBefore = first.drawnCount(sourceList);
      final historyBefore = first.history.length;
      expect(drawnBefore, 2);

      // ---- 第二次运行（模拟关掉程序再打开）----
      final second = DataStore();
      await second.load();

      expect(second.loadError, isNull);
      expect(second.lists.length, 1);
      final restored = second.currentList!;
      expect(restored.name, '持久化测试');
      expect(restored.people.map((e) => e.name).toList(), ['a', 'b', 'c', 'd']);

      // 关键：不重复模式的进度必须接上，而不是从头开始
      expect(second.drawnCount(restored), 2);
      expect(second.remaining(restored), 2);

      expect(second.config.githubRepo, 'someone/some-repo');
      expect(second.config.mode, DrawMode.repeat);
      expect(second.config.batchCount, 4);
      expect(second.config.animation, isFalse);
      expect(second.history.length, historyBefore);
    });

    test('恢复后继续抽，不会重复抽到已经抽过的人', () async {
      final first = DataStore();
      await first.createList(
        '继续抽',
        ['a', 'b', 'c'].map((e) => Person(name: e)).toList(),
      );
      final firstDraw = await first.draw(
        list: first.currentList!,
        mode: DrawMode.noRepeat,
        count: 2,
        allowDuplicateInBatch: false,
      );

      final second = DataStore();
      await second.load();
      final rest = await second.draw(
        list: second.currentList!,
        mode: DrawMode.noRepeat,
        count: 5,
        allowDuplicateInBatch: false,
      );

      expect(rest.names.length, 1, reason: '只剩 1 个人没抽过');
      expect(firstDraw.names.contains(rest.names.single), isFalse);
      expect(
        {...firstDraw.names, ...rest.names}.length,
        3,
        reason: '跨重启后整体仍不重复',
      );
    });

    test('全新的空目录：load() 会建出示例名单，不报错', () async {
      final store = DataStore();
      await store.load();
      expect(store.loadError, isNull);
      expect(store.lists, isNotEmpty);
      expect(store.currentList, isNotNull);
    });

    test('config.json 损坏时能降级到默认值，不崩', () async {
      await File(p.join(tmp.path, 'config.json')).writeAsString('{ 这不是合法 JSON');
      final store = DataStore();
      await store.load();
      expect(store.loadError, isNull);
      expect(store.config.mode, DrawMode.noRepeat);
      expect(store.config.batchCount, 1);
    });

    test('lists.json 损坏时降级到示例名单，不崩', () async {
      await File(p.join(tmp.path, 'lists.json')).writeAsString('[[[坏掉的数据');
      final store = DataStore();
      await store.load();
      expect(store.loadError, isNull);
      expect(store.lists, isNotEmpty);
    });
  });

  // ------------------------------------------------ 大名单不炸性能

  group('规模压测', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rp_scale_');
      AppPaths.overrideDataDirForTesting(tmp);
    });

    tearDown(() async {
      AppPaths.resetForTesting();
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('5000 人名单「全部抽完」在合理时间内完成且不重复', () async {
      final store = DataStore()..persist = false;
      const count = 5000;
      await store.createList(
        '大规模',
        List<Person>.generate(count, (i) => Person(name: '成员$i')),
      );
      final list = store.currentList!;

      final sw = Stopwatch()..start();
      final result = await store.draw(
        list: list,
        mode: DrawMode.noRepeat,
        count: count,
        allowDuplicateInBatch: false,
      );
      sw.stop();

      expect(result.names.length, count);
      expect(result.names.toSet().length, count, reason: '不该有重复');
      expect(result.roundFinished, isTrue);
      // 早期实现是 O(n^3)，5000 人会卡到没法用；留个宽松阈值防回归
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: '抽完 $count 人耗时 ${sw.elapsedMilliseconds}ms');
    });
  });
}
