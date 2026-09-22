import 'package:flutter/material.dart';

/// 界面主题选项。用户在主界面右上角随时切换，选择会记进 config.json。
enum AppThemeOption {
  light('light', '浅色', Color(0xFF3B6FE0), Brightness.light, Icons.light_mode_outlined),
  dark('dark', '深色', Color(0xFF6F9BFF), Brightness.dark, Icons.dark_mode_outlined),
  pink('pink', '粉色', Color(0xFFE0518F), Brightness.light, Icons.local_florist_outlined),
  blue('blue', '浅蓝', Color(0xFF3FA9E0), Brightness.light, Icons.water_drop_outlined),
  purple('purple', '紫色', Color(0xFF7C5CE0), Brightness.light, Icons.auto_awesome_outlined),
  system('system', '跟随系统', Color(0xFF3B6FE0), Brightness.light, Icons.brightness_auto_outlined);

  const AppThemeOption(
    this.id,
    this.label,
    this.seed,
    this.brightness,
    this.icon,
  );

  /// 存进 config.json 的稳定标识，改枚举顺序也不会错乱。
  final String id;
  final String label;

  /// Material 3 的种子色，整个配色由它派生。
  final Color seed;
  final Brightness brightness;
  final IconData icon;

  bool get followsSystem => this == AppThemeOption.system;

  ThemeMode get themeMode => switch (this) {
        AppThemeOption.system => ThemeMode.system,
        AppThemeOption.dark => ThemeMode.dark,
        _ => ThemeMode.light,
      };

  static AppThemeOption fromId(String? id) => AppThemeOption.values.firstWhere(
        (option) => option.id == id,
        orElse: () => AppThemeOption.light,
      );
}

/// 由种子色 + 明暗构建主题。
///
/// [fontFamily] 只在桌面端传值（Windows 上显式指定中文字体，
/// 避免个别系统下中文发虚）；移动端传 null 用系统默认。
ThemeData buildAppTheme(
  Color seed,
  Brightness brightness, {
  String? fontFamily,
}) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ),
    fontFamily: fontFamily,
    visualDensity: VisualDensity.compact,
  );
}
