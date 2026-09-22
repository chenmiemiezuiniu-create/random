import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:random_picker/core/models.dart';
import 'package:random_picker/core/paths.dart';
import 'package:random_picker/core/store.dart';
import 'package:random_picker/core/theme.dart';
import 'package:random_picker/main.dart';

/// 把界面渲染成 PNG，用来**肉眼检查配色和排版**。
///
/// 背景：`flutter test` 默认用没有字形的占位字体（文字全画成方块），
/// 所以这里先手动加载真实字体，否则生成的图片没有任何参考价值。
///
/// 生成/更新图片：
///     flutter test --update-goldens test/golden_test.dart
///
/// 注意：这些基准图跟机器上装的字体强相关，换一台机器跑会因为字体差异
/// 而对比失败。所以它的定位是「开发期看一眼」，不适合放进 CI。
void main() {
  late Directory tmp;
  late DataStore store;

  setUpAll(() async {
    await _loadFont(
      'MaterialIcons',
      r'D:\computer\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    );
    // 应用在 Windows 上指定了 Microsoft YaHei。测试里用黑体顶上 ——
    // 目的只是看中文排版是否正常，字形差异无所谓。
    await _loadFont('Microsoft YaHei', r'C:\Windows\Fonts\simhei.ttf');
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rp_golden_');
    AppPaths.overrideDataDirForTesting(tmp);
    store = DataStore()..persist = false;
    store.config.animation = false;
    await store.createList(
      '示例名单',
      ['张三', '李四', '王五', '赵六', '钱七']
          .map((e) => Person(name: e))
          .toList(),
    );
  });

  tearDown(() async {
    AppPaths.resetForTesting();
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(RandomPickerApp(store: store));
    await tester.pumpAndSettle();
  }

  for (final option in AppThemeOption.values) {
    testWidgets('主题截图：${option.label}', (tester) async {
      store.config.themeId = option.id;
      await pumpApp(tester);

      // 抽一次，让结果区和历史都有内容，截图才有代表性
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/theme_${option.id}.png'),
      );
    });
  }

  testWidgets('主题菜单展开的样子', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/theme_menu.png'),
    );
  });
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    // ignore: avoid_print
    print('跳过字体 $family：找不到 $path');
    return;
  }
  final bytes = Uint8List.fromList(file.readAsBytesSync());
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
