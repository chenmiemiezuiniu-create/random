import 'dart:convert';

import 'package:http/http.dart' as http;

/// 检查更新时的可预期错误，消息直接展示给用户。
class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateInfo {
  UpdateInfo({
    required this.current,
    required this.latest,
    required this.notes,
    this.downloadUrl,
    this.releaseUrl,
  });

  final String current;
  final String latest;
  final String notes;
  final String? downloadUrl;
  final String? releaseUrl;

  bool get hasUpdate => compareVersions(latest, current) > 0;
}

/// 语义化版本比较：a > b 返回 1，a < b 返回 -1，相等返回 0。
/// 自动忽略 `v` 前缀和 `-beta` 之类的后缀。
int compareVersions(String a, String b) {
  List<int> parse(String version) {
    final cleaned = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final main = cleaned.split(RegExp(r'[-+]')).first;
    final out = <int>[];
    for (final part in main.split('.')) {
      final match = RegExp(r'^\d+').firstMatch(part.trim());
      out.add(match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0));
    }
    while (out.length < 3) {
      out.add(0);
    }
    return out;
  }

  final pa = parse(a);
  final pb = parse(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

const Map<String, String> _apiHeaders = {
  'Accept': 'application/vnd.github+json',
  'User-Agent': 'RandomPicker-UpdateChecker',
};

/// 把用户可能填的各种写法统一成 `owner/repo`。
String normalizeRepo(String input) {
  var s = input.trim();
  s = s.replaceFirst(RegExp(r'^https?://github\.com/', caseSensitive: false), '');
  s = s.replaceFirst(RegExp(r'^git@github\.com:'), '');
  s = s.replaceAll(RegExp(r'\.git$'), '');
  s = s.replaceAll(RegExp(r'/+$'), '');
  final parts = s.split('/').where((e) => e.trim().isNotEmpty).toList();
  if (parts.length >= 2) {
    return '${parts[0]}/${parts[1]}';
  }
  return s;
}

/// 从 Release 附件里挑最合适的下载包。
///
/// 真实数据教会我们的事：microsoft/PowerToys 的 Release 里同时挂着 x64 和 arm64
/// 的安装包，而 JSON 里 arm64 排在前面 —— 只取「第一个匹配的附件」会在 x64 机器上
/// 把 arm64 的包装下来。所以选择顺序是：
///
/// 1. 后缀匹配 **且** 名字看起来是 Windows x64 的；
/// 2. 只要求后缀匹配；
/// 3. 兜底取第一个附件。
///
/// `assetSuffix` 为空表示不限后缀。
///
/// 公开而非私有：这样 `test/logic_test.dart` 能用合成数据离线覆盖这条规则，
/// 不必依赖真实网络。
String? pickAssetUrl(List<dynamic>? assets, String assetSuffix) {
  if (assets == null) return null;
  final candidates = assets.whereType<Map>().toList();
  if (candidates.isEmpty) return null;

  String? urlOf(Map<dynamic, dynamic> asset) {
    final url = (asset['browser_download_url'] ?? '').toString();
    return url.isEmpty ? null : url;
  }

  bool suffixMatches(Map<dynamic, dynamic> asset) {
    if (assetSuffix.isEmpty) return true;
    final name = (asset['name'] ?? '').toString().toLowerCase();
    return name.endsWith(assetSuffix.toLowerCase());
  }

  bool looksWindowsX64(Map<dynamic, dynamic> asset) {
    final name = (asset['name'] ?? '').toString().toLowerCase();
    if (name.contains('arm') || name.contains('aarch')) return false;
    return name.contains('x64') || name.contains('amd64') || name.contains('win');
  }

  for (final asset in candidates) {
    if (suffixMatches(asset) && looksWindowsX64(asset)) return urlOf(asset);
  }
  for (final asset in candidates) {
    if (suffixMatches(asset)) return urlOf(asset);
  }
  return urlOf(candidates.first);
}

/// 检查更新。
///
/// 1. 先读 GitHub Releases 的最新发布（`/releases/latest`），能拿到 tag、
///    更新说明和安装包直链 —— 这是推荐用法。
/// 2. 如果仓库还没发过 Release（404），退回到读仓库里的 `version.json`。
Future<UpdateInfo> checkForUpdate({
  required String repo,
  required String currentVersion,
  String branch = 'main',
  String assetSuffix = '',
}) async {
  final cleanRepo = normalizeRepo(repo);
  if (!cleanRepo.contains('/')) {
    throw UpdateException(
      '还没有配置更新源。\n\n'
      '请点右上角「设置」，在「GitHub 仓库」里填写：用户名/仓库名\n'
      '例如：zhangsan/random-picker',
    );
  }

  // 非空类型 + 默认值：分析器能证明走到最后一条 throw 时它必定已被赋值，
  // 若写成可空再 `?? '无'` 会被 flutter analyze 判为 dead_null_aware_expression。
  Object networkError = '未能读取发布信息。';

  // ---------- 方案一：GitHub Releases ----------
  try {
    final uri = Uri.parse('https://api.github.com/repos/$cleanRepo/releases/latest');
    final resp = await http.get(uri, headers: _apiHeaders).timeout(const Duration(seconds: 15));

    if (resp.statusCode == 200) {
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '').toString();

      final download = pickAssetUrl(data['assets'], assetSuffix);

      return UpdateInfo(
        current: currentVersion,
        latest: tag.isEmpty ? currentVersion : tag,
        notes: (data['body'] ?? '').toString().trim(),
        downloadUrl: (download == null || download.isEmpty) ? null : download,
        releaseUrl: (data['html_url'] ?? '').toString(),
      );
    }
    if (resp.statusCode == 404) {
      networkError = '仓库 $cleanRepo 还没有发布过 Release。';
    } else if (resp.statusCode == 403) {
      networkError = 'GitHub 接口访问受限（403），可能是短时间内请求太多，过一会儿再试。';
    } else {
      networkError = 'GitHub 返回了 HTTP ${resp.statusCode}。';
    }
  } catch (e) {
    networkError = e;
  }

  // ---------- 方案二：仓库里的 version.json ----------
  try {
    final uri = Uri.parse('https://raw.githubusercontent.com/$cleanRepo/$branch/version.json');
    final resp = await http
        .get(uri, headers: const {'User-Agent': 'RandomPicker-UpdateChecker'})
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 200) {
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is Map) {
        final download = (data['download'] ?? '').toString();
        return UpdateInfo(
          current: currentVersion,
          latest: (data['version'] ?? currentVersion).toString(),
          notes: (data['notes'] ?? data['changelog'] ?? '').toString().trim(),
          downloadUrl: download.isEmpty ? null : download,
          releaseUrl: 'https://github.com/$cleanRepo/releases',
        );
      }
    }
  } catch (_) {
    // 两种方案都失败，下面统一抛错
  }

  throw UpdateException(
    '检查更新失败：读不到 $cleanRepo 的发布信息。\n\n'
    '请依次确认：\n'
    '1. 仓库地址写对了（格式：用户名/仓库名）\n'
    '2. 仓库是 Public（公开）的\n'
    '3. 已经发过一个 Release，或者仓库根目录有 version.json\n\n'
    '详细原因：$networkError',
  );
}
