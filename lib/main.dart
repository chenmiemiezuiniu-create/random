import 'dart:io';

import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/store.dart';
import 'core/theme.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = DataStore();
  await store.load();

  runApp(RandomPickerApp(store: store));
}

class RandomPickerApp extends StatelessWidget {
  const RandomPickerApp({super.key, required this.store});

  final DataStore store;

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
