import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

/// 让 Windows 原生标题栏跟随应用主题色。
///
/// 用的是 DWM 的 `DWMWA_CAPTION_COLOR`(35) / `DWMWA_TEXT_COLOR`(36)，
/// 需要 Windows 11（内部版本 22000 以上）。更早的系统上这两个调用会失败，
/// 这里静默忽略 —— 顶多标题栏保持系统默认配色，其它功能一概不受影响。
///
/// 为什么不引第三方窗口库（window_manager / bitsdojo_window 之类）：
/// 整个需求就是三次 DwmSetWindowAttribute，用 dart:ffi 直接调最省事，
/// 也少一个需要跟着 Flutter 版本升级的依赖。
class WindowStyle {
  WindowStyle._();

  /// Flutter Windows runner 固定用这个窗口类名（见 windows/runner/win32_window.cpp）。
  static const String _windowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

  // DWM 窗口属性编号
  static const int _attrUseImmersiveDarkMode = 20;
  static const int _attrCaptionColor = 35;
  static const int _attrTextColor = 36;

  /// 最近一次真正应用到窗口上的颜色，用来避免重复调系统 API。
  static int? _appliedCaption;

  static final DynamicLibrary _dwmapi = DynamicLibrary.open('dwmapi.dll');
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

  static final _setWindowAttribute = _dwmapi.lookupFunction<
      Int32 Function(IntPtr hwnd, Uint32 attr, Pointer<Uint32> value, Uint32 size),
      int Function(int hwnd, int attr, Pointer<Uint32> value, int size)>(
    'DwmSetWindowAttribute',
  );

  static final _findWindow = _user32.lookupFunction<
      IntPtr Function(Pointer<Utf16> className, Pointer<Utf16> windowName),
      int Function(Pointer<Utf16> className, Pointer<Utf16> windowName)>(
    'FindWindowW',
  );

  /// 把标题栏设成 [caption] 底色 + [onCaption] 文字色。
  ///
  /// [dark] 决定右上角最小化/最大化/关闭三个按钮画成亮色还是暗色 ——
  /// 浅色标题栏配深色按钮，深色标题栏配浅色按钮，否则按钮会看不见。
  static void applyCaption({
    required Color caption,
    required Color onCaption,
    required bool dark,
  }) {
    if (!Platform.isWindows) return;

    final argb = _toArgb(caption);
    if (_appliedCaption == argb) return;
    _appliedCaption = argb;

    try {
      final hwnd = _mainWindowHandle();
      if (hwnd == 0) return; // 窗口还没建好，或当前不在 GUI 环境（比如测试）
      _setDword(hwnd, _attrCaptionColor, _colorRef(caption));
      _setDword(hwnd, _attrTextColor, _colorRef(onCaption));
      _setDword(hwnd, _attrUseImmersiveDarkMode, dark ? 1 : 0);
    } catch (e) {
      // 绝对不能让换主题这件事把应用弄崩
      debugPrint('设置标题栏配色失败（不影响使用）：$e');
    }
  }

  static int _mainWindowHandle() {
    final className = _windowClassName.toNativeUtf16();
    try {
      return _findWindow(className, nullptr);
    } finally {
      malloc.free(className);
    }
  }

  static void _setDword(int hwnd, int attribute, int value) {
    final ptr = calloc<Uint32>();
    try {
      ptr.value = value;
      _setWindowAttribute(hwnd, attribute, ptr, sizeOf<Uint32>());
    } finally {
      calloc.free(ptr);
    }
  }

  /// COLORREF 是 `0x00BBGGRR`，字节序跟 ARGB 正好相反。
  static int _colorRef(Color color) {
    final r = (color.r * 255).round() & 0xFF;
    final g = (color.g * 255).round() & 0xFF;
    final b = (color.b * 255).round() & 0xFF;
    return (b << 16) | (g << 8) | r;
  }

  static int _toArgb(Color color) =>
      ((color.a * 255).round() << 24) |
      ((color.r * 255).round() << 16) |
      ((color.g * 255).round() << 8) |
      (color.b * 255).round();
}
