import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_applier.dart';
import '../core/updater.dart';

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (_) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  bool _done = false;
  UpdateProgress? _progress;
  String? _error;

  Future<void> _startUpdate() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await UpdateApplier(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ).apply(widget.info);

      if (!mounted) return;
      setState(() => _done = true);

      // 让用户看清「即将重启」，然后把进程交出去。
      // 必须真的退出 —— 外部脚本正等着我们的 PID 消失才会开始覆盖文件。
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      exit(0);
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '更新失败：$e\n\n可以到发布页手动下载。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 更新中不允许误触关闭：脚本已经准备好，中途放弃会留下半套东西
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              _done ? Icons.check_circle_outline : Icons.system_update_alt,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Text(_done ? '更新完成' : '发现新版本'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_busy && !_done) ..._buildIdle(scheme),
                if (_busy) ..._buildProgress(scheme),
                if (_done) ..._buildDone(),
              ],
            ),
          ),
        ),
        actions: _buildActions(),
      ),
    );
  }

  List<Widget> _buildIdle(ColorScheme scheme) {
    final info = widget.info;
    return [
      Text('当前版本：v${info.current}    最新版本：${info.latest}'),
      if (info.notes.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('更新内容：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: SelectableText(
              info.notes,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _error!,
            style: TextStyle(fontSize: 12.5, color: scheme.onErrorContainer),
          ),
        ),
      ],
      const SizedBox(height: 14),
      Text(
        '点「立即更新」会在程序内下载新版本，然后自动替换并重新启动。\n'
        '你的名单和设置不受影响。',
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      ),
    ];
  }

  List<Widget> _buildProgress(ColorScheme scheme) {
    final progress = _progress;
    final stage = progress?.stage ?? UpdateStage.downloading;
    final fraction = progress?.fraction;
    final percent = fraction == null ? null : (fraction * 100).round();

    return [
      Text('当前版本：v${widget.info.current}  →  ${widget.info.latest}'),
      const SizedBox(height: 20),
      Text(stage.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: fraction, // null -> 不确定进度（拿不到总长度时）
          minHeight: 10,
          backgroundColor: scheme.surfaceContainerHighest,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          if (percent != null)
            Text('$percent%',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          if (progress != null && stage == UpdateStage.downloading)
            Text(
              '${_formatBytes(progress.received)}'
              '${progress.total == null ? '' : ' / ${_formatBytes(progress.total!)}'}',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        '下载和替换期间请不要关闭程序。',
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      ),
    ];
  }

  List<Widget> _buildDone() {
    return const [
      Text('新版本已经就位，程序马上自动重启。'),
      SizedBox(height: 12),
      Text('如果窗口没有自动回来，双击文件夹里的 random_picker.exe 即可。'),
    ];
  }

  List<Widget> _buildActions() {
    if (_busy) {
      return const [
        Padding(
          padding: EdgeInsets.only(right: 8),
          child: Text('更新中…', style: TextStyle(fontSize: 13)),
        ),
      ];
    }
    if (_done) {
      return const [
        Padding(
          padding: EdgeInsets.only(right: 8),
          child: Text('正在重启…', style: TextStyle(fontSize: 13)),
        ),
      ];
    }

    final info = widget.info;
    final hasDownload = (info.downloadUrl ?? '').isNotEmpty;
    final releaseUrl = info.releaseUrl;

    return [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('以后再说'),
      ),
      if (releaseUrl != null && releaseUrl.isNotEmpty)
        TextButton(
          onPressed: () => _openExternal(releaseUrl),
          // 出错时这个按钮就是「手动下载」的出路
          child: Text(_error == null ? '打开发布页' : '手动下载'),
        ),
      if (hasDownload)
        FilledButton(
          onPressed: _startUpdate,
          child: Text(_error == null ? '立即更新' : '重试'),
        ),
    ];
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

Future<void> _openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
