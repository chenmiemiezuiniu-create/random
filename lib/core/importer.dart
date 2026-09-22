import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class ImportResult {
  ImportResult({required this.name, required this.people});

  final String name;
  final List<Person> people;
}

/// 导入过程中的可预期错误，消息直接展示给用户。
class ImportException implements Exception {
  ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从文件导入名单。支持 `.txt`（一行一个名字）和 `.json`。
Future<ImportResult> importFromFile(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw ImportException('文件不存在：$filePath');
  }

  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw ImportException('这个文件是空的。');
  }

  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw ImportException(
      '这个文件不是 UTF-8 编码，读不出来。\n\n'
      '解决办法：用 Windows 记事本打开它 → 「另存为」→ 右下角编码选 UTF-8 → 保存，再重新导入。',
    );
  }

  // 去掉 UTF-8 BOM
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }

  final fallbackName = p.basenameWithoutExtension(filePath);
  if (p.extension(filePath).toLowerCase() == '.json') {
    return parseJsonImport(text, fallbackName);
  }
  return parseTextImport(text, fallbackName);
}

/// 解析「一行一个名字」的文本。
///
/// * 空行会被忽略
/// * `#` 或 `//` 开头的行视为注释
/// * `张三,3` 表示张三权重为 3（数字越大越容易被抽中）
/// * `lenient = true` 时不抛异常，允许结果为空（界面内编辑器用）
ImportResult parseTextImport(String text, String name, {bool lenient = false}) {
  final people = <Person>[];

  for (final rawLine in const LineSplitter().convert(text)) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#') || line.startsWith('//')) continue;

    var weight = 1.0;
    final comma = line.lastIndexOf(',');
    if (comma > 0) {
      final tail = line.substring(comma + 1).trim();
      final parsed = double.tryParse(tail);
      if (parsed != null) {
        weight = parsed;
        line = line.substring(0, comma).trim();
      }
    }
    if (line.isEmpty) continue;
    if (!weight.isFinite || weight < 0) weight = 0;

    people.add(Person(name: line, weight: weight));
  }

  if (people.isEmpty && !lenient) {
    throw ImportException('没有解析到任何名字。请确认文件内容是一行一个名字。');
  }

  return ImportResult(
    name: name.trim().isEmpty ? '导入的名单' : name.trim(),
    people: people,
  );
}

/// 解析 JSON 名单。支持这些结构：
///
/// ```json
/// ["张三", "李四"]
/// ```
/// ```json
/// {"name": "三班", "people": ["张三", {"name": "李四", "weight": 2}]}
/// ```
/// ```json
/// {"listName": "三班", "names": [{"name": "张三", "weight": 1, "note": "班长"}]}
/// ```
ImportResult parseJsonImport(String text, String fallbackName) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw ImportException('JSON 格式有误：${e.message}');
  }

  var listName = fallbackName;
  final people = <Person>[];

  void addItem(dynamic item) {
    if (item is String) {
      final n = item.trim();
      if (n.isNotEmpty) people.add(Person(name: n));
    } else if (item is Map) {
      final person = Person.fromJson(Map<String, dynamic>.from(item));
      if (person.name.isNotEmpty) people.add(person);
    }
  }

  if (decoded is List) {
    for (final item in decoded) {
      addItem(item);
    }
  } else if (decoded is Map) {
    final map = Map<String, dynamic>.from(decoded);
    final rawName = map['name'] ?? map['listName'] ?? map['title'];
    if (rawName is String && rawName.trim().isNotEmpty) {
      listName = rawName.trim();
    }
    final array = map['people'] ?? map['names'] ?? map['items'] ?? map['list'];
    if (array is List) {
      for (final item in array) {
        addItem(item);
      }
    } else {
      throw ImportException(
        'JSON 里没找到名单数组。\n'
        '支持字段名：people / names / items / list，或者直接用一个字符串数组。',
      );
    }
  } else {
    throw ImportException('不支持的 JSON 结构，顶层应该是数组或对象。');
  }

  if (people.isEmpty) {
    throw ImportException('JSON 里没有解析到任何名字。');
  }

  return ImportResult(
    name: listName.trim().isEmpty ? '导入的名单' : listName.trim(),
    people: people,
  );
}
