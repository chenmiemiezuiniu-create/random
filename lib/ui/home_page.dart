import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/importer.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/updater.dart';
import 'list_editor_dialog.dart';
import 'settings_dialog.dart';
import 'update_dialog.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});

  final DataStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _countCtrl = TextEditingController();
  final Random _rng = Random();

  Timer? _rollTimer;
  bool _rolling = false;
  bool _checkingUpdate = false;
  List<String> _display = <String>[];

  DataStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _countCtrl.text = store.config.batchCount.toString();
    store.addListener(_onStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckUpdate());
  }

  @override
  void dispose() {
    _rollTimer?.cancel();
    store.removeListener(_onStoreChanged);
    _countCtrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 工具方法

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        // 必须抬高：浮动 SnackBar 默认贴着底部，而「开始抽取」按钮行也在底部，
        // 两者位置几乎完全重叠，不抬起来会把主按钮挡住、点不动。
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 104),
        duration: const Duration(milliseconds: 2600),
      ));
  }

  Future<void> _showError(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(child: SelectableText(message)),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<String?> _askText(String title, String label, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('确定')),
        ],
      ),
    );
  }

  int get _count {
    final v = int.tryParse(_countCtrl.text.trim());
    if (v == null || v < 1) return 1;
    return v > 9999 ? 9999 : v;
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ---------------------------------------------------------------- 抽取

  Future<void> _doDraw() async {
    if (_rolling) return;

    final list = store.currentList;
    if (list == null) {
      _toast('请先创建或选择一个名单');
      return;
    }
    if (list.people.isEmpty) {
      _toast('「${list.name}」里还没有人，先编辑名单加上名字');
      return;
    }

    final mode = store.config.mode;
    if (mode == DrawMode.noRepeat && store.remaining(list) == 0) {
      final again = await _askNewRound(list);
      if (again != true) return;
      await store.resetRound(list);
    }

    final result = await store.draw(
      list: list,
      mode: mode,
      count: _count,
      allowDuplicateInBatch: store.config.allowDuplicateInBatch,
    );

    if (!mounted) return;

    if (result.names.isEmpty) {
      _toast('没有可抽的人（是不是权重都设成 0 了？）');
      return;
    }

    if (!store.config.animation) {
      setState(() => _display = result.names);
      if (result.roundFinished) _toast('本轮已抽完');
      return;
    }

    _startRolling(list, result);
  }

  void _startRolling(NameList list, DrawResult result) {
    _rollTimer?.cancel();

    final names = list.people.map((e) => e.name).toList();
    final rollCount = result.names.length > 200 ? 200 : result.names.length;
    var ticks = 0;
    const totalTicks = 18;

    setState(() {
      _rolling = true;
      _display = result.names;
    });

    _rollTimer = Timer.periodic(const Duration(milliseconds: 70), (timer) {
      ticks++;
      if (ticks >= totalTicks) {
        timer.cancel();
        if (!mounted) return;
        setState(() {
          _rolling = false;
          _display = result.names;
        });
        if (result.roundFinished) {
          _toast('本轮已抽完，点「开始新一轮」可以重新开始');
        }
        return;
      }
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _display = List<String>.generate(rollCount, (_) => names[_rng.nextInt(names.length)]);
      });
    });
  }

  Future<bool?> _askNewRound(NameList list) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本轮已抽完'),
        content: Text(
            '「${list.name}」里的 ${store.eligibleCount(list)} 个人已经全部抽过一遍了。\n\n要开始新一轮吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始新一轮')),
        ],
      ),
    );
  }

  Future<void> _resetRound(NameList list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始新一轮？'),
        content: Text('「${list.name}」本轮已经抽了 ${store.drawnCount(list)} 个人，'
            '还没抽的有 ${store.remaining(list)} 个。\n\n'
            '开始新一轮会把所有人都放回池子，重新开始。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始新一轮')),
        ],
      ),
    );
    if (ok != true) return;
    await store.resetRound(list);
    setState(() => _display = <String>[]);
    _toast('已开始新一轮，${store.eligibleCount(list)} 个人全部回到池子里');
  }

  // ------------------------------------------------------------ 名单管理

  Future<void> _importFromFile() async {
    // 刻意不用 const：XTypeGroup 的常量构造在不同版本里不一致，避免编译期踩坑
    final typeGroup = XTypeGroup(label: '名单文件', extensions: <String>['txt', 'json']);
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null) return;

    try {
      final result = await importFromFile(file.path);
      if (!mounted) return;
      final name = await _askText('导入名单', '给这份名单起个名字', result.name);
      if (name == null) return;
      await store.createList(
        name.trim().isEmpty ? result.name : name.trim(),
        result.people,
      );
      _toast('已导入 ${result.people.length} 个人');
    } on ImportException catch (e) {
      await _showError('导入失败', e.message);
    } catch (e) {
      await _showError('导入失败', '$e');
    }
  }

  Future<void> _createList() async {
    final name = await _askText('新建名单', '名单名称', '新名单');
    if (name == null) return;
    final list = await store.createList(
      name.trim().isEmpty ? '新名单' : name.trim(),
      <Person>[],
    );
    await _editList(list);
  }

  Future<void> _editList(NameList list) async {
    final result = await showListEditor(context, list);
    if (result == null) return;
    await store.updateList(list, name: result.name, people: result.people);
    _toast('已保存「${result.name}」，共 ${result.people.length} 人');
  }

  Future<void> _renameList(NameList list) async {
    final name = await _askText('重命名名单', '名单名称', list.name);
    if (name == null || name.trim().isEmpty) return;
    await store.updateList(list, name: name);
  }

  Future<void> _deleteList(NameList list) async {
    if (store.lists.length <= 1) {
      _toast('至少要保留一个名单');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除名单'),
        content: Text('确定要删除「${list.name}」（${list.size} 人）吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.deleteList(list);
    setState(() => _display = <String>[]);
    _toast('已删除「${list.name}」');
  }

  // ------------------------------------------------------------ 更新 & 设置

  Future<void> _autoCheckUpdate() async {
    final repo = store.config.githubRepo.trim();
    if (!store.config.autoCheckUpdate || repo.isEmpty) return;
    try {
      final info = await checkForUpdate(
        repo: repo,
        currentVersion: kAppVersion,
        branch: store.config.updateBranch,
      );
      if (!mounted) return;
      if (info.hasUpdate) {
        await showUpdateDialog(context, info);
      }
    } catch (_) {
      // 静默失败：自动检查时网络不好不打扰用户
    }
  }

  Future<void> _checkUpdate({required bool manual}) async {
    final repo = store.config.githubRepo.trim();
    if (repo.isEmpty) {
      if (manual) {
        await _showError(
          '还没配置更新源',
          '请先点右上角「设置」，在「GitHub 仓库」里填写你的仓库。\n\n'
          '格式：用户名/仓库名\n例如：zhangsan/random-picker',
        );
      }
      return;
    }

    if (manual) setState(() => _checkingUpdate = true);
    try {
      final info = await checkForUpdate(
        repo: repo,
        currentVersion: kAppVersion,
        branch: store.config.updateBranch,
      );
      if (!mounted) return;
      if (info.hasUpdate) {
        await showUpdateDialog(context, info);
      } else if (manual) {
        _toast('已经是最新版本 v${info.current}');
      }
    } on UpdateException catch (e) {
      if (manual && mounted) await _showError('检查更新失败', e.message);
    } catch (e) {
      if (manual && mounted) await _showError('检查更新失败', '$e');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openSettings() async {
    await showSettingsDialog(context, store);
    _countCtrl.text = store.config.batchCount.toString();
    if (mounted) setState(() {});
  }

  Future<void> _openDataDir() async {
    if (store.dataPath.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', <String>[store.dataPath]);
      } else {
        await launchUrl(Uri.file(store.dataPath));
      }
    } catch (e) {
      await _showError('打不开目录', '$e\n\n路径：${store.dataPath}');
    }
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('使用说明'),
        content: const SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              '【两种抽取模式】\n'
              '· 不重复抽取：抽中的人本轮不再出现，直到名单里的人全部抽完；\n'
              '  想提前重来，点「开始新一轮」即可。\n'
              '· 可重复抽取：每次都在完整名单里随机，同一个人可能被反复抽到。\n\n'
              '【一次抽多个】\n'
              '在「每次抽取人数」里填数字，或点 1 / 2 / 3 / 5 / 全部 快捷按钮。\n\n'
              '【导入名单】\n'
              '· txt：一行一个名字；写成「张三,3」表示权重 3（数字越大越容易被抽中）；\n'
              '  写成「张三,0」表示这个人本轮不参与抽取。\n'
              '· json：["张三","李四"] 或 {"name":"三班","people":[{"name":"张三","weight":2}]}\n'
              '· 也可以直接在界面上新建名单、手动输入或粘贴。\n'
              '· 注意：txt 必须是 UTF-8 编码，GBK 的老文件请先用记事本另存为 UTF-8。\n\n'
              '【数据存在哪】\n'
              '所有数据都在程序旁边的 RandomPickerData 文件夹里，不写 C 盘用户目录。\n'
              '把整个文件夹删掉 = 零残留。',
            ),
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final list = store.currentList;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const Icon(Icons.casino_outlined),
            const SizedBox(width: 8),
            const Text(kAppName, style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            _versionChip(),
          ],
        ),
        actions: [
          _buildThemeMenu(),
          TextButton.icon(
            onPressed: _checkingUpdate ? null : () => _checkUpdate(manual: true),
            icon: _checkingUpdate
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.system_update_alt, size: 18),
            label: const Text('检查更新'),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '使用说明',
            onPressed: _showHelp,
            icon: const Icon(Icons.help_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          SizedBox(width: 330, child: _buildListPanel()),
          const VerticalDivider(width: 1),
          Expanded(child: _buildDrawPanel(list)),
        ],
      ),
      bottomNavigationBar: _buildStatusBar(),
    );
  }

  Widget _versionChip() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'v$kAppVersion',
        style: TextStyle(fontSize: 11.5, color: scheme.onSecondaryContainer),
      ),
    );
  }

  /// 右上角的主题切换菜单。摆在「检查更新」左边。
  Widget _buildThemeMenu() {
    final scheme = Theme.of(context).colorScheme;
    final current = AppThemeOption.fromId(store.config.themeId);

    return PopupMenuButton<AppThemeOption>(
      tooltip: '切换主题',
      // 固定用调色板图标：一眼能看出这是「换配色」，
      // 也避免跟着当前主题变形导致用户找不到入口。
      icon: Icon(Icons.palette_outlined, color: scheme.onSurfaceVariant),
      onSelected: (option) => store.setTheme(option.id),
      itemBuilder: (ctx) => [
        for (final option in AppThemeOption.values)
          PopupMenuItem<AppThemeOption>(
            value: option,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _themeLeading(option, scheme),
                const SizedBox(width: 12),
                Text(
                  option.label,
                  style: TextStyle(
                    fontWeight:
                        option == current ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                // 当前选中的打勾；用固定宽度占位让各条目左对齐
                SizedBox(
                  width: 26,
                  child: option == current
                      ? Icon(Icons.check, size: 16, color: scheme.primary)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 主题选项左侧的指示器。
  ///
  /// 浅色 / 深色 / 跟随系统 表达的是「明暗模式」，用太阳 / 月亮 / 电脑图标；
  /// 粉色 / 浅蓝 / 紫色 表达的是具体颜色，用一个该色的实心圆点。
  Widget _themeLeading(AppThemeOption option, ColorScheme scheme) {
    const size = 18.0;
    final symbol = option.symbolIcon;

    if (symbol != null) {
      return Icon(symbol, size: size, color: scheme.onSurfaceVariant);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: option.seed,
        shape: BoxShape.circle,
        // 细边框：浅蓝这类浅色在浅背景上也能看清轮廓
        border: Border.all(color: scheme.outlineVariant),
      ),
    );
  }

  Widget _buildListPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
          child: Row(
            children: [
              const Text('名单', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const Spacer(),
              IconButton(
                tooltip: '导入 txt / json',
                onPressed: _importFromFile,
                icon: const Icon(Icons.file_open_outlined),
              ),
              IconButton(
                tooltip: '新建名单',
                onPressed: _createList,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: store.lists.length,
            itemBuilder: (ctx, i) {
              final list = store.lists[i];
              final selected = list.id == store.config.currentListId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: selected ? scheme.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    leading: Icon(
                      selected ? Icons.check_circle : Icons.list_alt_outlined,
                      size: 20,
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                    ),
                    title: Text(
                      list.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected ? scheme.onPrimaryContainer : null,
                      ),
                    ),
                    subtitle: Text(
                      '${list.size} 人',
                      style: TextStyle(color: selected ? scheme.onPrimaryContainer : null),
                    ),
                    onTap: () => store.selectList(list.id),
                    trailing: PopupMenuButton<String>(
                      tooltip: '更多',
                      icon: const Icon(Icons.more_vert, size: 18),
                      onSelected: (value) {
                        switch (value) {
                          case 'edit':
                            _editList(list);
                          case 'rename':
                            _renameList(list);
                          case 'duplicate':
                            store.duplicateList(list);
                          case 'delete':
                            _deleteList(list);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑名单')),
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'duplicate', child: Text('复制一份')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '提示：txt 一行一个名字，写成「张三,3」可设置权重；'
            '同名的人只会被当作同一个名字展示。',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawPanel(NameList? list) {
    final scheme = Theme.of(context).colorScheme;
    final mode = store.config.mode;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('抽取模式：', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Flexible(
                child: SegmentedButton<DrawMode>(
                  segments: const [
                    ButtonSegment(
                      value: DrawMode.noRepeat,
                      label: Text('不重复抽取'),
                      icon: Icon(Icons.filter_alt_off_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: DrawMode.repeat,
                      label: Text('可重复抽取'),
                      icon: Icon(Icons.replay, size: 18),
                    ),
                  ],
                  selected: <DrawMode>{mode},
                  onSelectionChanged: (selection) {
                    store.setMode(selection.first);
                    setState(() => _display = <String>[]);
                  },
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  mode == DrawMode.noRepeat
                      ? '抽中的人本轮不再出现，抽完为止'
                      : '每次都在完整名单里随机，可被反复抽到',
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(child: _buildResultArea(list, scheme)),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text('每次抽取人数：', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: _countCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  ),
                  onChanged: (v) => store.setBatchCount(int.tryParse(v) ?? 1),
                ),
              ),
              const SizedBox(width: 10),
              // 用 Wrap + Expanded，窗口变窄时快捷按钮会自动换行而不是溢出
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final n in const <int>[1, 2, 3, 5])
                      ActionChip(
                        label: Text('$n'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          _countCtrl.text = '$n';
                          store.setBatchCount(n);
                        },
                      ),
                    ActionChip(
                      label: const Text('全部'),
                      visualDensity: VisualDensity.compact,
                      onPressed: (list == null || store.eligibleCount(list) == 0)
                          ? null
                          : () {
                              final n = store.eligibleCount(list);
                              _countCtrl.text = '$n';
                              store.setBatchCount(n);
                            },
                    ),
                  ],
                ),
              ),
              if (mode == DrawMode.repeat)
                TextButton.icon(
                  onPressed: () => showSettingsDialog(context, store),
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(
                    store.config.allowDuplicateInBatch ? '允许一次内重复' : '一次内不重复',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _rolling ? null : _doDraw,
                  icon: Icon(_rolling ? Icons.hourglass_top : Icons.play_arrow_rounded),
                  label: Text(
                    _rolling ? '抽取中…' : '开始抽取（$_count 人）',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: (list == null || mode != DrawMode.noRepeat || _rolling)
                    ? null
                    : () => _resetRound(list),
                icon: const Icon(Icons.restart_alt),
                label: const Text('开始新一轮'),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _showHistory,
                icon: const Icon(Icons.history),
                label: const Text('历史'),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultArea(NameList? list, ColorScheme scheme) {
    final mode = store.config.mode;
    final remaining = list == null ? 0 : store.remaining(list);
    final drawn = list == null ? 0 : store.drawnCount(list);
    final total = list == null ? 0 : store.eligibleCount(list);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.emoji_events_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                _rolling ? '抽取中…' : '抽取结果',
                style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (list != null)
                Flexible(
                  child: Text(
                    mode == DrawMode.noRepeat
                        ? '${list.name} · 已抽 $drawn / $total，本轮剩余 $remaining'
                        : '${list.name} · 共 $total 人 · 放回抽取',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Center(
              child: _display.isEmpty
                  ? Text(
                      list == null
                          ? '先创建一个名单'
                          : (list.size == 0
                              ? '这个名单还是空的，点左边的「更多 → 编辑名单」加人'
                              : '点下面的「开始抽取」'),
                      style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
                    )
                  : SingleChildScrollView(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 12,
                        children: _display.map(_nameChip).toList(),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nameChip(String name) {
    final scheme = Theme.of(context).colorScheme;
    final big = _display.length <= 6;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      padding: EdgeInsets.symmetric(horizontal: big ? 26 : 18, vertical: big ? 16 : 10),
      decoration: BoxDecoration(
        color: _rolling ? scheme.surfaceContainerHighest : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _rolling ? scheme.outlineVariant : scheme.primary,
          width: 1.5,
        ),
      ),
      child: Text(
        name,
        style: TextStyle(
          fontSize: big ? 32 : 20,
          fontWeight: FontWeight.w700,
          color: _rolling ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Future<void> _showHistory() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Text('抽取历史'),
            const Spacer(),
            if (store.history.isNotEmpty)
              TextButton(
                onPressed: () {
                  store.clearHistory();
                  Navigator.pop(ctx);
                  _toast('历史已清空');
                },
                child: const Text('清空'),
              ),
          ],
        ),
        content: SizedBox(
          width: 560,
          height: 460,
          child: store.history.isEmpty
              ? const Center(child: Text('还没有抽取记录'))
              : ListView.separated(
                  itemCount: store.history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final record = store.history[i];
                    return ListTile(
                      dense: true,
                      title: Text(record.names.join('、')),
                      subtitle: Text(
                        '${_fmtTime(record.time)} · ${record.listName} · ${record.mode.label}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
    setState(() {});
  }

  Widget _buildStatusBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      color: scheme.surfaceContainerHighest.withAlpha(150),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              store.loadError != null
                  ? '数据目录不可用：${store.loadError}'
                  : '数据目录（删掉整个文件夹即零残留）：${store.dataPath}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _openDataDir,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('打开目录', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}
