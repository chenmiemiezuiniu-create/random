import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 读取系统代理设置。
///
/// 为什么需要这个：Dart 的 `HttpClient` **不会自动使用 Windows 的系统代理**
/// （它默认直连）。而 GitHub 的下载地址会重定向到
/// `release-assets.githubusercontent.com` 这类域名，在一些网络环境下
/// 直连解析不了、只有走代理才通 —— 浏览器能下载正是因为浏览器读了系统代理。
/// 不处理的话，更新检测能成功（api.github.com 通常直连可达）但下载永远失败。
class SystemProxy {
  SystemProxy._();

  static String? _cached;
  static bool _probed = false;

  static const int _hkeyCurrentUser = 0x80000001;
  static const int _keyRead = 0x20019;
  static const String _internetSettings =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

  static final _regOpenKeyEx = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
      int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');

  static final _regQueryValueEx = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');

  static final _regCloseKey =
      _advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

  /// 返回形如 `127.0.0.1:7897` 的代理地址；没有启用代理时返回 null。
  static String? address() {
    if (_probed) return _cached;
    _probed = true;
    try {
      _cached = _read();
    } catch (_) {
      _cached = null;
    }
    return _cached;
  }

  /// 测试用：清掉缓存。
  static void resetCacheForTesting() {
    _probed = false;
    _cached = null;
  }

  static String? _read() {
    // 非 Windows 平台看环境变量就够了
    if (!Platform.isWindows) {
      return Platform.environment['https_proxy'] ??
          Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['http_proxy'] ??
          Platform.environment['HTTP_PROXY'];
    }

    final hKey = calloc<IntPtr>();
    final subKey = _internetSettings.toNativeUtf16();
    try {
      final opened = _regOpenKeyEx(
        _hkeyCurrentUser,
        subKey,
        0,
        _keyRead,
        hKey,
      );
      if (opened != 0) return null;

      final enabled = _readDword(hKey.value, 'ProxyEnable');
      if (enabled != 1) return null;

      final server = _readString(hKey.value, 'ProxyServer');
      if (server == null || server.trim().isEmpty) return null;

      // ProxyServer 可能是 "host:port"，也可能是
      // "http=host:port;https=host:port" 这种分协议写法
      final raw = server.trim();
      if (raw.contains('=')) {
        for (final part in raw.split(';')) {
          final kv = part.split('=');
          if (kv.length == 2 && kv[0].trim().toLowerCase() == 'https') {
            return kv[1].trim();
          }
        }
        for (final part in raw.split(';')) {
          final kv = part.split('=');
          if (kv.length == 2 && kv[0].trim().toLowerCase() == 'http') {
            return kv[1].trim();
          }
        }
        return null;
      }
      return raw;
    } finally {
      _regCloseKey(hKey.value);
      calloc.free(hKey);
      malloc.free(subKey);
    }
  }

  static int? _readDword(int hKey, String name) {
    final namePtr = name.toNativeUtf16();
    final type = calloc<Uint32>();
    final data = calloc<Uint32>();
    final size = calloc<Uint32>()..value = 4;
    try {
      final rc = _regQueryValueEx(
        hKey,
        namePtr,
        nullptr,
        type,
        data.cast<Uint8>(),
        size,
      );
      return rc == 0 ? data.value : null;
    } finally {
      calloc.free(namePtr);
      calloc.free(type);
      calloc.free(data);
      calloc.free(size);
    }
  }

  static String? _readString(int hKey, String name) {
    final namePtr = name.toNativeUtf16();
    final type = calloc<Uint32>();
    final size = calloc<Uint32>();
    try {
      // 先问长度
      var rc = _regQueryValueEx(
        hKey,
        namePtr,
        nullptr,
        type,
        nullptr,
        size,
      );
      if (rc != 0 || size.value == 0) return null;

      final buffer = calloc<Uint8>(size.value);
      try {
        rc = _regQueryValueEx(
          hKey,
          namePtr,
          nullptr,
          type,
          buffer,
          size,
        );
        if (rc != 0) return null;
        return buffer.cast<Utf16>().toDartString();
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(namePtr);
      calloc.free(type);
      calloc.free(size);
    }
  }
}
