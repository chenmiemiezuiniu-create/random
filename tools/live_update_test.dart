import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:random_picker/core/paths.dart';
import 'package:random_picker/core/update_applier.dart';
import 'package:random_picker/core/updater.dart';

/// **真实联网**的自动更新全流程演练。
///
/// 从 GitHub 下载真正的安装包，完整走一遍
/// 下载 → 校验 → 解压 → 备份 → 生成交接脚本 → 外部脚本替换 → 新版启动。
///
/// 之所以不放进默认测试套件：会联网、要下 11 MB、还会真的启动一个窗口。
/// 手动运行：
///     flutter test tools/live_update_test.dart
void main() {
  test('从 GitHub 真下载，完成替换，并且新版能启动', () async {
    final tmp = await Directory.systemTemp.createTemp('rp_live_');
    // 必须先把数据目录指到临时位置，否则会在真实程序旁边乱写
    AppPaths.overrideDataDirForTesting(Directory(p.join(tmp.path, 'data')));

    // 假安装目录：塞一个占位的旧 exe，等更新把它换掉
    final install = Directory(p.join(tmp.path, 'install'))
      ..createSync(recursive: true);
    File(p.join(install.path, exeFileName)).writeAsStringSync('OLD-EXE-PLACEHOLDER');

    // 从真实仓库读最新版本（假装自己是 0.9.0）
    final info = await checkForUpdate(
      repo: 'chenmiemiezuiniu-create/random',
      currentVersion: '0.9.0',
    );
    expect(info.hasUpdate, isTrue, reason: '应当检测到新版本，实际最新是 ${info.latest}');
    expect(info.downloadUrl, isNotNull);
    expect(info.downloadSize, isNotNull, reason: 'Release 附件应当带 size 字段');

    // 真的下载 + 解压 + 交接
    final stages = <UpdateStage>[];
    var maxFraction = 0.0;
    final applier = UpdateApplier(onProgress: (progress) {
      if (stages.isEmpty || stages.last != progress.stage) {
        stages.add(progress.stage);
      }
      final f = progress.fraction;
      if (f != null && f > maxFraction) maxFraction = f;
    });
    await applier.apply(info, installDirOverride: install);

    expect(stages.first, UpdateStage.downloading);
    expect(stages, contains(UpdateStage.extracting));
    expect(stages.last, UpdateStage.launching);
    expect(maxFraction, closeTo(1.0, 0.01), reason: '下载进度应当走满 100%');

    // 等外部脚本跑完（它会删掉自己）
    final script = File(p.join(tmp.path, 'data', 'update', 'apply.cmd'));
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (script.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(script.existsSync(), isFalse, reason: '交接脚本没能跑完');

    // ---- 核心验证：安装目录里现在是真正的新版本 ----
    final exe = File(p.join(install.path, exeFileName));
    expect(exe.existsSync(), isTrue, reason: '新版 exe 应当已就位');
    expect(
      exe.lengthSync(),
      greaterThan(50000),
      reason: 'exe 应当是真程序，而不是原来那个占位文本',
    );
    expect(
      File(p.join(install.path, 'flutter_windows.dll')).existsSync(),
      isTrue,
      reason: 'Flutter 运行时 DLL 应当被带进来',
    );
    expect(
      Directory(p.join(install.path, 'data')).existsSync(),
      isTrue,
      reason: 'Flutter 资源目录 data\\ 应当被带进来',
    );
    // 更新目录里不该留下垃圾
    expect(
      Directory(p.join(tmp.path, 'data', 'update', 'staging')).existsSync(),
      isFalse,
      reason: 'staging 应当被清理',
    );
    expect(
      Directory(p.join(tmp.path, 'data', 'update', 'backup')).existsSync(),
      isFalse,
      reason: 'backup 应当被清理',
    );

    // ---- 新版被脚本启动后，应当在旁边建出自己的数据目录 ----
    final launchedData = Directory(p.join(install.path, 'RandomPickerData'));
    final launchDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (!launchedData.existsSync() && DateTime.now().isBefore(launchDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    expect(
      launchedData.existsSync(),
      isTrue,
      reason: '更新后的程序被启动后，应当自动建出 RandomPickerData\\ —— 这证明新 exe 真的能跑',
    );
    // ignore: avoid_print
    print('✓ 新版启动成功，数据目录已生成: ${launchedData.path}');

    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 4)));
}
