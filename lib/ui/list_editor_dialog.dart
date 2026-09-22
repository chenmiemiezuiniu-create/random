import 'package:flutter/material.dart';

import '../core/importer.dart';
import '../core/models.dart';

class ListEditResult {
  ListEditResult({required this.name, required this.people});

  final String name;
  final List<Person> people;
}

Future<ListEditResult?> showListEditor(BuildContext context, NameList list) {
  return showDialog<ListEditResult>(
    context: context,
    builder: (_) => _ListEditorDialog(list: list),
  );
}

class _ListEditorDialog extends StatefulWidget {
  const _ListEditorDialog({required this.list});

  final NameList list;

  @override
  State<_ListEditorDialog> createState() => _ListEditorDialogState();
}

class _ListEditorDialogState extends State<_ListEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bodyCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.list.name);
    _bodyCtrl = TextEditingController(
      text: widget.list.people.map(_toLine).join('\n'),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  String _toLine(Person person) {
    if (person.weight == 1.0) return person.name;
    final w = person.weight == person.weight.roundToDouble()
        ? person.weight.toInt().toString()
        : person.weight.toString();
    return '${person.name},$w';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑名单'),
      content: SizedBox(
        width: 560,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名单名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '一行一个名字。想设权重就写成「名字,权重」，例如 张三,3 —— 数字越大越容易被抽中。\n'
              '以 # 开头的行会被忽略。',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _bodyCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '张三\n李四\n王五',
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final result = parseTextImport(_bodyCtrl.text, name, lenient: true);
    if (result.people.isEmpty) {
      setState(() => _error = '名单是空的。至少要写一个名字，或者点「取消」放弃修改。');
      return;
    }
    Navigator.pop(
      context,
      ListEditResult(
        name: name.isEmpty ? '未命名名单' : name,
        people: result.people,
      ),
    );
  }
}
