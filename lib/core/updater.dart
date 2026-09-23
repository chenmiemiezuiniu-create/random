import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'system_proxy.dart';

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
    this.downloadSize,
    this.downloadSha256,
    this.releaseUrl,
  });

  final String current;
  final String latest;
  final String notes;
  final String? downloadUrl;

  /// 安装包字节数，来自 Release 附件的 size 字段。
  /// 下载完拿它校验完整性，避免把半截文件当成功。
  final int? downloadSize;

  /// 安装包的 SHA-256（小写十六进制），来自 Release 附件的 digest 字段。
  ///
  /// 有它才能确认下载到的东西和发布端**逐字节一致** ——
  /// 字节数校验挡不住内容被替换（比如未来接第三方镜像时的投毒）。
  final String? downloadSha256;
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
Map<dynamic, dynamic>? pickAsset(List<dynamic>? assets, String assetSuffix) {
  if (assets == null) return null;
  final candidates = assets.whereType<Map>().toList();
  if (candidates.isEmpty) return null;

  bool hasUrl(Map<dynamic, dynamic> asset) =>
      (asset['browser_download_url'] ?? '').toString().isNotEmpty;

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
    if (hasUrl(asset) && suffixMatches(asset) && looksWindowsX64(asset)) {
      return asset;
    }
  }
  for (final asset in candidates) {
    if (hasUrl(asset) && suffixMatches(asset)) return asset;
  }
  final first = candidates.first;
  return hasUrl(first) ? first : null;
}

/// 只要下载直链。见 [pickAsset] 的选择规则。
String? pickAssetUrl(List<dynamic>? assets, String assetSuffix) {
  final asset = pickAsset(assets, assetSuffix);
  if (asset == null) return null;
  final url = (asset['browser_download_url'] ?? '').toString();
  return url.isEmpty ? null : url;
}

/// 下载安装包到 [destination]，边下边回调进度。
///
/// [onProgress] 的第二个参数在拿不到总长度时为 null（进度条退化成不确定态）。
/// 下完会校验字节数和 SHA-256；对不上就抛 [UpdateException]，
/// 绝不把半截或被替换过的文件当成成功。
Future<void> downloadUpdate({
  required String url,
  required File destination,
  required int? expectedSize,
  String? expectedSha256,
  void Function(int received, int? total)? onProgress,
  http.Client? client,
}) async {
  final httpClient = client ?? _buildClient();
  final ownsClient = client == null;

  try {
    final request = http.Request('GET', Uri.parse(url));
    request.headers['User-Agent'] = 'RandomPicker-Updater';
    final response = await httpClient.send(request).timeout(
          const Duration(seconds: 30),
        );

    if (response.statusCode != 200) {
      throw UpdateException(
        '下载失败：服务器返回 HTTP ${response.statusCode}。\n\n'
        '如果一直失败，可以到发布页手动下载。',
      );
    }

    final total = response.contentLength ?? expectedSize;
    if (!await destination.parent.exists()) {
      await destination.parent.create(recursive: true);
    }

    final sink = destination.openWrite();
    var received = 0;
    try {
      // 必须给流加超时：网络卡住时 `await for` 会永远等下去，
      // 界面就永远停在「下载中…」。超过 60 秒收不到任何数据就判定失败。
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
        onTimeout: (sink) => sink.addError(
          UpdateException('下载超时：60 秒没有收到数据。\n\n可以到发布页手动下载。'),
        ),
      )) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (total != null && received != total) {
      throw UpdateException(
        '下载不完整：应该 $total 字节，实际只有 $received 字节。\n\n'
        '可能是网络中断，请重试。',
      );
    }
    if (received == 0) {
      throw UpdateException('下载到了空文件，请重试。');
    }

    // 哈希校验：这是唯一能确认「下载到的东西就是发布端那一个」的手段。
    // 字节数相同但内容被换掉（镜像投毒、中间人替换）只有它能挡住。
    final want = expectedSha256?.trim().toLowerCase();
    if (want != null && want.isNotEmpty) {
      final actual = await sha256OfFile(destination);
      if (actual != want) {
        throw UpdateException(
          '安装包校验失败（SHA-256 对不上），已中止更新。\n\n'
          '期望：$want\n实际：$actual\n\n'
          '可能是下载过程中被破坏或被替换。请重试；'
          '如果反复出现，请到发布页手动下载。',
        );
      }
    }
  } on UpdateException {
    rethrow;
  } catch (e) {
    throw UpdateException('下载失败：$e');
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// 计算文件的 SHA-256（小写十六进制），流式读取，不会把整个文件读进内存。
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
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

  // 记录「有没有任何一次真的拿到了响应」，用来区分
  // 「连不上」和「连上了但接口说没有」—— 前者才值得换直连重试。
  var gotResponse = false;
  Object? lastConnectionError;

  UpdateInfo? found;
  try {
    found = await withProxyFallback<UpdateInfo?>((client) async {
      // ---------- 方案一：GitHub Releases ----------
      try {
        final uri = Uri.parse('https://api.github.com/repos/$cleanRepo/releases/latest');
        final resp = await client
            .get(uri, headers: _apiHeaders)
            .timeout(const Duration(seconds: 20));
        gotResponse = true;

        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final tag = (data['tag_name'] ?? '').toString();

          final asset = pickAsset(data['assets'], assetSuffix);
          final download = asset == null
              ? null
              : (asset['browser_download_url'] ?? '').toString();
          final size = asset?['size'];
          // GitHub 的格式是 "sha256:xxxx"；不是这个前缀就当作没有
          const prefix = 'sha256:';
          final digest = (asset?['digest'] ?? '').toString().toLowerCase();
          final sha = digest.startsWith(prefix)
              ? digest.substring(prefix.length).trim()
              : '';

          return UpdateInfo(
            current: currentVersion,
            latest: tag.isEmpty ? currentVersion : tag,
            notes: (data['body'] ?? '').toString().trim(),
            downloadUrl: (download == null || download.isEmpty) ? null : download,
            downloadSize: size is num ? size.toInt() : null,
            downloadSha256: sha.isEmpty ? null : sha,
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
        lastConnectionError = e;
        networkError = e;
      }

      // ---------- 方案二：仓库里的 version.json ----------
      try {
        final uri = Uri.parse('https://raw.githubusercontent.com/$cleanRepo/$branch/version.json');
        final resp = await client
            .get(uri, headers: const {'User-Agent': 'RandomPicker-UpdateChecker'})
            .timeout(const Duration(seconds: 20));
        gotResponse = true;

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
      } catch (e) {
        lastConnectionError = e;
      }

      // 两种方案一个响应都没拿到 —— 这是连接问题，抛出去让外层换直连重试。
      // 先拷到局部变量：闭包里赋过值的变量不会被类型提升，直接 throw 会报
      // 「Object? 不能赋给 Object」。
      final err = lastConnectionError;
      if (!gotResponse && err != null) {
        throw err;
      }
      return null;
    });
  } catch (e) {
    networkError = e;
  }
  if (found != null) return found;

  throw UpdateException(
    '检查更新失败：读不到 $cleanRepo 的发布信息。\n\n'
    '请依次确认：\n'
    '1. 仓库地址写对了（格式：用户名/仓库名）\n'
    '2. 仓库是 Public（公开）的\n'
    '3. 已经发过一个 Release，或者仓库根目录有 version.json\n\n'
    '详细原因：$networkError',
  );
}

/// 先走系统代理跑 [run]，代理不通就退回直连再跑一次。
///
/// 为什么需要：代理软件被关掉或崩溃后，注册表里的 `ProxyEnable` 可能还留着 1，
/// 这时所有请求都会打到一个**没人监听的端口**上，而直连本来是通的。
/// 不处理的话用户会看到「检查更新失败」，但其实网络没问题。
///
/// [shouldFallback] 决定某个错误值不值得换直连。默认**只对连接类错误回退**：
/// `UpdateException` 表示「已经连上服务器但结果不对」（HTTP 404、字节数不符、
/// 哈希对不上），这种情况换个通道结果只会一样，重试纯属浪费流量。
Future<T> withProxyFallback<T>(
  Future<T> Function(http.Client client) run, {
  bool Function(Object error)? shouldFallback,
}) async {
  final proxy = SystemProxy.address();
  final fallback = shouldFallback ?? (Object e) => e is! UpdateException;

  if (proxy == null || proxy.isEmpty) {
    final direct = _buildClient();
    try {
      return await run(direct);
    } finally {
      direct.close();
    }
  }

  final proxied = _buildClient();
  try {
    return await run(proxied);
  } catch (e) {
    if (!fallback(e)) rethrow;
    final direct = _buildClient(forceDirect: true);
    try {
      return await run(direct);
    } finally {
      direct.close();
    }
  } finally {
    proxied.close();
  }
}

/// 构造一个会走系统代理的 HTTP 客户端。
///
/// Dart 的 HttpClient 默认直连，**不会读 Windows 的系统代理**。
/// 而 GitHub 的下载地址会重定向到 `release-assets.githubusercontent.com`
/// 这类域名，在没有代理的网络环境下直接解析不了 —— 表现就是
/// 「能检测到新版本，但下载永远卡住」。
///
/// [forceDirect] 用于代理失效时的兜底重试。
http.Client _buildClient({bool forceDirect = false}) {
  final inner = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  final proxy = forceDirect ? null : SystemProxy.address();
  if (proxy != null && proxy.isNotEmpty) {
    inner.findProxy = (Uri uri) {
      // 本机地址绝不能走代理 —— 否则连本地服务（以及离线调试）都会失败
      final host = uri.host.toLowerCase();
      if (host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '::1' ||
          host.endsWith('.localhost')) {
        return 'DIRECT';
      }
      return 'PROXY $proxy';
    };
  }
  return IOClient(inner);
}
