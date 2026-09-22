import 'dart:io';

import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/store.dart';
import 'core/theme.dart';
import 'core/window_style.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = DataStore();
  await store.load();

  runApp(RandomPickerApp(store: store));
}

class RandomPickerApp extends StatefulWidget {
  const RandomPickerApp({super.key, required this.store});

  final DataStore store;

  @override
  State<RandomPickerApp> createState() => _RandomPickerAppState();
}

class _RandomPickerAppState extends State<RandomPickerApp> {
  /// 上一次同步标题栏时的「主题 + 明暗」组合，避免每次列表变动都重算配色。
  String? _lastStyleKey;

  DataStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_syncTitleBar);
    // 窗口句柄要等第一帧之后才存在
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTitleBar());
  }

  @override
  void dispose() {
    store.removeListener(_syncTitleBar);
    super.dispose();
  }

  /// 当前实际生效的明暗（「跟随系统」时取决于系统设置）。
  Brightness get _effectiveBrightness {
    final option = AppThemeOption.fromId(store.config.themeId);
    if (option.followsSystem) {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
    return option.brightness;
  }

  /// 让 Windows 原生标题栏跟应用主题保持一致。
  ///
  /// 不做这一步的话，系统是深色主题、应用选了浅色/粉色时，
  /// 标题栏会是一条突兀的黑条。
  void _syncTitleBar() {
    final option = AppThemeOption.fromId(store.config.themeId);
    final brightness = _effectiveBrightness;

    final key = '${option.id}/${brightness.name}';
    if (key == _lastStyleKey) return;
    _lastStyleKey = key;

    final scheme = ColorScheme.fromSeed(
      seedColor: option.seed,
      brightness: brightness,
    );
    WindowStyle.applyCaption(
      caption: scheme.primary,
      onCaption: scheme.onPrimary,
      dark: brightness == Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    // Windows 上显式指定中文字体，避免个别系统下中文发虚
    final fontFamily = isDesktop ? 'Microsoft YaHei' : null;

    // 主题切换必须立刻生效，所以整个 MaterialApp 跟着 store 重建。
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final option = AppThemeOption.fromId(store.config.themeId);
        return MaterialApp(
          title: kAppName,
          debugShowCheckedModeBanner: false,
          // 浅色和深色都给出，这样「跟随系统」才有东西可切
          theme: buildAppTheme(option.seed, Brightness.light, fontFamily: fontFamily),
          darkTheme: buildAppTheme(option.seed, Brightness.dark, fontFamily: fontFamily),
          themeMode: option.themeMode,
          home: HomePage(store: store),
        );
      },
    );
  }
}
