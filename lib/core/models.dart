import 'dart:math';

/// 抽取模式。
enum DrawMode {
  /// 不放回：抽过的人本轮不再出现，直到抽完。
  noRepeat('noRepeat', '不重复抽取'),

  /// 放回：每次抽取都在完整名单里随机。
  repeat('repeat', '可重复抽取');

  const DrawMode(this.id, this.label);

  final String id;
  final String label;

  static DrawMode fromId(String? id) => DrawMode.values.firstWhere(
        (m) => m.id == id,
        orElse: () => DrawMode.noRepeat,
      );
}

/// 名单里的一个人。weight 为抽取权重，默认 1。
class Person {
  Person({required this.name, this.weight = 1.0, this.note = ''});

  String name;
  double weight;
  String note;

  /// 权重非法（负数 / NaN / Infinity）时按 0 处理，即永远不会被抽中。
  double get safeWeight => (weight.isFinite && weight > 0) ? weight : 0.0;

  factory Person.fromJson(Map<String, dynamic> json) {
    double w = 1.0;
    final raw = json['weight'] ?? json['rate'] ?? json['probability'];
    if (raw is num) {
      w = raw.toDouble();
    } else if (raw is String) {
      w = double.tryParse(raw.trim()) ?? 1.0;
    }
    if (!w.isFinite || w < 0) w = 0;

    return Person(
      name: (json['name'] ?? json['person'] ?? json['title'] ?? '').toString().trim(),
      weight: w,
      note: (json['note'] ?? json['remark'] ?? json['desc'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'weight': weight,
        if (note.isNotEmpty) 'note': note,
      };
}

/// 一份名单。
class NameList {
  NameList({
    required this.id,
    required this.name,
    required this.people,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String id;
  String name;
  List<Person> people;
  DateTime createdAt;

  int get size => people.length;

  factory NameList.fromJson(Map<String, dynamic> json) {
    final people = <Person>[];
    final raw = json['people'] ?? json['names'];
    if (raw is List) {
      for (final item in raw) {
        if (item is String) {
          final n = item.trim();
          if (n.isNotEmpty) people.add(Person(name: n));
        } else if (item is Map) {
          final person = Person.fromJson(Map<String, dynamic>.from(item));
          if (person.name.isNotEmpty) people.add(person);
        }
      }
    }
    final id = (json['id'] ?? '').toString();
    final name = (json['name'] ?? '').toString();
    return NameList(
      id: id.isEmpty ? newId() : id,
      name: name.isEmpty ? '未命名名单' : name,
      people: people,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'people': people.map((e) => e.toJson()).toList(),
      };

  static String newId() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${r.nextInt(1 << 22).toRadixString(36)}';
  }
}

/// 应用配置，存于 data/config.json。
class AppConfig {
  AppConfig({
    this.githubRepo = 'chenmiemiezuiniu-create/random',
    this.updateBranch = 'main',
    this.autoCheckUpdate = true,
    this.mode = DrawMode.noRepeat,
    this.batchCount = 1,
    this.allowDuplicateInBatch = false,
    this.animation = true,
    this.themeId = 'light',
    this.currentListId,
  });

  /// 形如 "用户名/仓库名"。默认指向本项目的发布仓库，
  /// 这样用户拿到 exe 就能自动检查更新，不用手动配置。
  String githubRepo;
  String updateBranch;
  bool autoCheckUpdate;
  DrawMode mode;
  int batchCount;

  /// 可重复模式下，同一次批量抽取里是否允许出现同一个人。
  bool allowDuplicateInBatch;

  /// 抽取时是否播放滚动动画。
  bool animation;

  /// 界面主题，对应 AppThemeOption.id。默认浅色，保持老用户看到的样子。
  String themeId;
  String? currentListId;

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final count = json['batchCount'];
    return AppConfig(
      githubRepo: (json['githubRepo'] ?? 'chenmiemiezuiniu-create/random').toString(),
      updateBranch: (json['updateBranch'] ?? 'main').toString(),
      autoCheckUpdate: json['autoCheckUpdate'] != false,
      mode: DrawMode.fromId(json['mode']?.toString()),
      batchCount: count is num ? count.toInt() : 1,
      allowDuplicateInBatch: json['allowDuplicateInBatch'] == true,
      animation: json['animation'] != false,
      themeId: (json['themeId'] ?? 'light').toString(),
      currentListId: json['currentListId']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'githubRepo': githubRepo,
        'updateBranch': updateBranch,
        'autoCheckUpdate': autoCheckUpdate,
        'mode': mode.id,
        'batchCount': batchCount,
        'allowDuplicateInBatch': allowDuplicateInBatch,
        'animation': animation,
        'themeId': themeId,
        'currentListId': currentListId,
      };
}

/// 一次抽取的历史记录，存于 data/history.json。
class DrawRecord {
  DrawRecord({
    required this.time,
    required this.listName,
    required this.mode,
    required this.names,
  });

  final DateTime time;
  final String listName;
  final DrawMode mode;
  final List<String> names;

  factory DrawRecord.fromJson(Map<String, dynamic> json) {
    final names = <String>[];
    final raw = json['names'];
    if (raw is List) {
      for (final item in raw) {
        names.add(item.toString());
      }
    }
    return DrawRecord(
      time: DateTime.tryParse((json['time'] ?? '').toString()) ?? DateTime.now(),
      listName: (json['listName'] ?? '').toString(),
      mode: DrawMode.fromId(json['mode']?.toString()),
      names: names,
    );
  }

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'listName': listName,
        'mode': mode.id,
        'names': names,
      };
}
