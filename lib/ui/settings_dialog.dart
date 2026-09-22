import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/store.dart';

Future<bool> showSettingsDialog(BuildContext context, DataStore store) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _SettingsDialog(store: store),
  );
  return result == true;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.store});

  final DataStore store;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _repoCtrl;
  late bool _autoCheck;
  late bool _animation;
  late bool _allowDuplicateInBatch;

  @override
  void initState() {
    super.initState();
    final config = widget.store.config;
    _repoCtrl = TextEditingController(text: config.githubRepo);
    _autoCheck = config.autoCheckUpdate;
    _animation = config.animation;
    _allowDuplicateInBatch = config.allowDuplicateInBatch;
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 600,
        height: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionTitle('版本更新'),
              TextField(
                controller: _repoCtrl,
                decoration: const InputDecoration(
                  labelText: 'GitHub 仓库',
                  hintText: '例如：zhangsan/random-picker',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoCheck,
                onChanged: (v) => setState(() => _autoCheck = v),
                title: const Text('启动时自动检查更新'),
                subtitle: const Text('发现新版本会弹窗提示；没配仓库时不会联网'),
              ),
              const SizedBox(height: 18),
              const _SectionTitle('抽取行为'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _animation,
                onChanged: (v) => setState(() => _animation = v),
                title: const Text('抽取时播放滚动动画'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _allowDuplicateInBatch,
                onChanged: (v) => setState(() => _allowDuplicateInBatch = v),
                title: const Text('可重复模式下，一次抽多人允许出现同一个人'),
                subtitle: const Text('关掉的话，同一次批量抽取里的人互不相同，下一次抽取时又都能被抽到'),
              ),
              const SizedBox(height: 18),
              const _SectionTitle('数据存放'),
              SelectableText(
                '当前数据目录：\n${widget.store.dataPath}\n\n'
                '所有数据都在程序旁边的 RandomPickerData 文件夹里，不会写到 C 盘用户目录。'
                '把程序文件夹整个删掉就什么都不剩。\n'
                '当前版本 v$kAppVersion',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Future<void> _save() async {
    final config = widget.store.config;
    config.githubRepo = _repoCtrl.text.trim();
    // updateBranch 不再暴露给用户，保留默认值 main 供 version.json 兜底方案使用
    config.autoCheckUpdate = _autoCheck;
    config.animation = _animation;
    config.allowDuplicateInBatch = _allowDuplicateInBatch;

    await widget.store.updateConfig(config);
    if (!mounted) return;
    Navigator.pop(context, true);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );
  }
}
