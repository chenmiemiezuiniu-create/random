import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/updater.dart';

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final downloadUrl =
          (info.downloadUrl != null && info.downloadUrl!.isNotEmpty)
              ? info.downloadUrl
              : info.releaseUrl;

      return AlertDialog(
        title: Row(
          children: [
            Icon(Icons.system_update_alt, color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('发现新版本'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本：v${info.current}    最新版本：${info.latest}'),
                if (info.notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('更新内容：', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        info.notes,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  '下载后解压覆盖原来的文件夹即可，RandomPickerData 里的名单和记录不会丢。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('以后再说'),
          ),
          if (info.releaseUrl != null && info.releaseUrl!.isNotEmpty)
            TextButton(
              onPressed: () => _open(info.releaseUrl!),
              child: const Text('打开发布页'),
            ),
          FilledButton(
            onPressed: (downloadUrl == null || downloadUrl.isEmpty)
                ? null
                : () => _open(downloadUrl),
            child: const Text('去下载'),
          ),
        ],
      );
    },
  );
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
