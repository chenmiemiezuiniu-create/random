import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:random_picker/core/constants.dart';
import 'package:random_picker/core/models.dart';
import 'package:random_picker/core/paths.dart';
import 'package:random_picker/core/store.dart';
import 'package:random_picker/core/theme.dart';
import 'package:random_picker/main.dart';

/// 界面层验证：用真实 widget 树 + 模拟点击，确认按钮点下去真的有反应。
///
/// 这一层是单元测试覆盖不到的 —— 「能启动」不等于「能用」。
void main() {
  late Directory tmp;
  late DataStore store;

  const names = <String>['甲', '乙', '丙'];

  /// 把测试画布设成指定尺寸（逻辑像素）。
  ///
  /// 坑：`tester.view.physicalSize` 是**物理**像素，而测试环境下
  /// `devicePixelRatio` 默认是 **3.0**。所以不显式设成 1.0 的话，
  /// 写 800×600 实际只得到 266×200 逻辑像素，整个界面会被挤爆。
  /// （我曾经据此误判「布局在 800×600 下会溢出」，其实是这个原因。）
  void useLogicalSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    useLogicalSize(tester, size);
    await tester.pumpWidget(RandomPickerApp(store: store));
    await tester.pumpAndSettle();
  }

  /// 结果区里出现了哪些名字（名单里的人名只会出现在结果区）
  List<String> shownNames() =>
      names.where((n) => find.text(n).evaluate().isNotEmpty).toList();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rp_widget_');
    AppPaths.overrideDataDirForTesting(tmp);
    store = DataStore();
    await store.createList(
      '测试名单',
      names.map((e) => Person(name: e)).toList(),
    );
    // 关掉滚动动画，测试才确定（否则有 18 次 × 70ms 的定时器）
    store.config.animation = false;
    // 关掉落盘：testWidgets 的 fake async 环境里真实文件 I/O 的 Future
    // 不会完成，会让抽取操作永远卡在 await 上。
    // 持久化本身由 logic_test.dart 用真实 I/O 覆盖。
    store.persist = false;
  });

  tearDown(() async {
    AppPaths.resetForTesting();
    try {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录偶尔会被占用删不掉，交给系统清理，不该让测试失败
    }
  });

  testWidgets('启动后显示应用名、版本号和名单', (tester) async {
    await pumpApp(tester);

    expect(find.text('随机抽人'), findsOneWidget);
    // 用常量而不是写死版本号，升版时才不会平白断掉
    expect(find.text('v$kAppVersion'), findsOneWidget);
    expect(find.text('测试名单'), findsWidgets);
    expect(find.text('3 人'), findsOneWidget);
    // 还没抽的时候应该显示引导文案
    expect(find.textContaining('点下面的'), findsOneWidget);
  });

  testWidgets('点「开始抽取」能抽出结果', (tester) async {
    await pumpApp(tester);
    expect(shownNames(), isEmpty);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(shownNames().length, 1, reason: '默认抽 1 人，结果区应正好一个名字');
    // 状态栏应更新为「已抽 1 / 3」
    expect(find.textContaining('已抽 1 / 3'), findsOneWidget);
  });

  testWidgets('一次抽多个人（改 batchCount 为 2）', (tester) async {
    store.config.batchCount = 2;
    await pumpApp(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(shownNames().length, 2, reason: '抽 2 人应出现 2 个不同的名字');
    expect(find.textContaining('已抽 2 / 3'), findsOneWidget);
  });

  testWidgets('不重复模式连抽 3 次恰好把 3 个人抽完', (tester) async {
    await pumpApp(tester);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
    }

    expect(store.remaining(store.currentList!), 0);
    expect(find.textContaining('已抽 3 / 3'), findsOneWidget);

    // 第 3 次抽取会弹一条 SnackBar 提示「本轮已抽完」，文案和下面的对话框标题
    // 完全一样。不先让它自动消失，find.text 会匹配到两个 widget。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('本轮已抽完'), findsNothing, reason: 'SnackBar 应已自动消失');

    // 现在再点，才轮到「本轮已抽完」对话框
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('本轮已抽完'), findsOneWidget);
    expect(find.textContaining('全部抽过一遍'), findsOneWidget);
  });

  testWidgets('切换到「可重复抽取」模式后界面文案跟着变', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('可重复抽取'));
    await tester.pumpAndSettle();

    expect(store.config.mode, DrawMode.repeat);
    expect(find.textContaining('放回抽取'), findsOneWidget);
  });

  testWidgets('改「每次抽取人数」输入框会写进配置', (tester) async {
    await pumpApp(tester);

    final field = find.byType(TextField).first;
    await tester.enterText(field, '3');
    await tester.pumpAndSettle();

    expect(store.config.batchCount, 3);
    expect(find.textContaining('开始抽取（3 人）'), findsOneWidget);
  });

  testWidgets('打开设置对话框不会崩，且能显示 GitHub 仓库输入框', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('GitHub 仓库'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsNothing);
  });

  testWidgets('打开使用说明对话框', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();

    expect(find.text('使用说明'), findsOneWidget);
    expect(find.textContaining('不重复抽取：抽中的人本轮不再出现'), findsOneWidget);
  });

  testWidgets('新建名单对话框能打开', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('新建名单'), findsWidgets);
    expect(find.text('名单名称'), findsWidgets);
  });

  // ------------------------------------------------------- 响应式布局

  group('窗口尺寸', () {
    // 布局溢出会被 Flutter 报成异常，testWidgets 会自动判定失败。
    // 所以「能 pump 完且没异常」本身就是无溢出的证据。

    for (final size in const <Size>[
      Size(1400, 900),
      Size(1280, 720), // Windows 模板默认
      Size(1100, 700),
      Size(1000, 650),
      Size(960, 640), // 下面这些是压力测试
      Size(900, 600),
    ]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 无布局溢出',
          (tester) async {
        await pumpApp(tester, size: size);
        expect(tester.takeException(), isNull);

        // 抽出结果后结果区有内容，再检查一次（内容变多最容易挤爆）
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // 一次性抽满，塞最多内容
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('窄窗口下「开始抽取」按钮仍可点击（不被遮挡）', (tester) async {
      await pumpApp(tester, size: const Size(1000, 650));

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(shownNames().length, 1);
    });
  });

  // ------------------------------------------------------- 名单编辑流程

  /// 对话框里的输入框，顺序是 [名称, 名单正文]。
  ///
  /// 不能写 `find.byType(TextField).at(1)` —— 主页面上那个「每次抽取人数」
  /// 输入框也在树里，会把索引顶偏一位（这个错误我踩过一次）。
  Finder dialogFields() => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );

  Future<void> openFirstListEditor(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑名单'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(dialogFields(), findsNWidgets(2));
  }

  testWidgets('编辑名单：改内容后保存会写进 store', (tester) async {
    await pumpApp(tester);
    await openFirstListEditor(tester);

    await tester.enterText(dialogFields().at(1), '张三\n李四\n王五,3');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final list = store.currentList!;
    expect(list.people.map((e) => e.name).toList(), ['张三', '李四', '王五']);
    expect(list.people.last.weight, 3.0);
    // 对话框应当已关闭
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('编辑名单：清空内容保存会被拦下并提示', (tester) async {
    await pumpApp(tester);
    await openFirstListEditor(tester);

    await tester.enterText(dialogFields().at(1), '   \n\n  ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 对话框不该关闭，且应给出说明
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('名单是空的'), findsOneWidget);
    expect(store.currentList!.people.length, 3, reason: '不该被清空');
  });

  testWidgets('开始新一轮：抽过之后能重置', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(store.remaining(store.currentList!), 2);

    await tester.tap(find.text('开始新一轮'));
    await tester.pumpAndSettle();
    expect(find.text('开始新一轮？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '开始新一轮'));
    await tester.pumpAndSettle();

    expect(store.remaining(store.currentList!), 3);
    expect(find.textContaining('已抽 0 / 3'), findsOneWidget);
  });

  // ------------------------------------------------------- 主题切换

  group('主题切换', () {
    /// 打开主题菜单。按钮图标是固定的调色板，不随当前主题变化。
    Future<void> openThemeMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.palette_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets('默认浅色，右上角有主题按钮', (tester) async {
      await pumpApp(tester);
      expect(store.config.themeId, 'light');
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
    });

    testWidgets('菜单里六个主题齐全', (tester) async {
      await pumpApp(tester);
      await openThemeMenu(tester);

      for (final option in AppThemeOption.values) {
        expect(find.text(option.label), findsOneWidget,
            reason: '主题菜单里缺少「${option.label}」');
      }
      expect(AppThemeOption.values.length, 6);
    });

    testWidgets('菜单左侧指示器：浅色=太阳、深色=月亮、跟随系统=电脑', (tester) async {
      await pumpApp(tester);
      await openThemeMenu(tester);

      expect(find.byIcon(Icons.wb_sunny_outlined), findsOneWidget);
      expect(find.byIcon(Icons.nightlight_outlined), findsOneWidget);
      expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
    });

    testWidgets('菜单左侧指示器：三个颜色主题用圆点而不是图标', (tester) async {
      await pumpApp(tester);
      await openThemeMenu(tester);

      // 粉色 / 浅蓝 / 紫色 的 symbolIcon 必须是 null（走圆点分支）
      for (final id in ['pink', 'blue', 'purple']) {
        final option = AppThemeOption.fromId(id);
        expect(option.symbolIcon, isNull, reason: '$id 应该用颜色圆点');
      }
      // 而这三个符号图标不该在菜单里出现
      expect(find.byIcon(Icons.local_florist_outlined), findsNothing);
      expect(find.byIcon(Icons.water_drop_outlined), findsNothing);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);

      // 圆点是画出来的 Container，数一下：3 个颜色主题 + 按钮自身不算
      final dots = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle);
      expect(dots, findsNWidgets(3), reason: '三个颜色主题应各有一个圆点');
    });

    testWidgets('切到深色：写入配置、themeMode 真的变了', (tester) async {
      await pumpApp(tester);
      await openThemeMenu(tester);

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();

      expect(store.config.themeId, 'dark');
      // 菜单关了，按钮还是调色板
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      // 深色主题必须真的被构建出来，而不是只改了个标志位
      expect(app.darkTheme?.colorScheme.brightness, Brightness.dark);
    });

    testWidgets('切到粉色：themeMode 是 light，且用的是粉色系配色', (tester) async {
      await pumpApp(tester);
      await openThemeMenu(tester);

      await tester.tap(find.text('粉色'));
      await tester.pumpAndSettle();

      expect(store.config.themeId, 'pink');
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.light);
      final primary = app.theme!.colorScheme.primary;
      // 粉色主题的主色应当偏红：红分量明显高于绿分量
      expect(primary.r, greaterThan(primary.g));
    });

    testWidgets('「跟随系统」的 themeMode 是 system', (tester) async {
      store.config.themeId = 'system';
      await pumpApp(tester);

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
    });

    testWidgets('六个主题逐个渲染 + 抽一次，全部不报错', (tester) async {
      for (final option in AppThemeOption.values) {
        store.config.themeId = option.id;
        await store.resetRound(store.currentList!);
        await pumpApp(tester);
        expect(tester.takeException(), isNull, reason: '${option.label} 渲染失败');

        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${option.label} 抽取后出错');
        expect(shownNames().length, 1, reason: '${option.label} 抽取结果不对');
      }
    });
  });

  // --------------------------------------------- 精简后的文案不应再出现

  group('已删除的说明文字', () {
    testWidgets('使用说明里不再有【版本更新】段落', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();

      expect(find.textContaining('版本更新'), findsNothing);
      expect(find.textContaining('GitHub 仓库（用户名/仓库名）'), findsNothing);
      // 其它段落要还在，别误删
      expect(find.textContaining('【两种抽取模式】'), findsOneWidget);
      expect(find.textContaining('【数据存在哪】'), findsOneWidget);
    });

    testWidgets('设置里不再有仓库格式提示、默认分支、发布说明块', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('默认分支'), findsNothing);
      expect(find.textContaining('也可以直接粘贴完整仓库网址'), findsNothing);
      expect(find.textContaining('怎么在 GitHub 上发布新版本'), findsNothing);
      expect(find.textContaining('Draft a new release'), findsNothing);

      // 该留的还在
      expect(find.text('GitHub 仓库'), findsOneWidget);
      expect(find.text('启动时自动检查更新'), findsOneWidget);
      expect(find.text('抽取时播放滚动动画'), findsOneWidget);
    });
  });
}
