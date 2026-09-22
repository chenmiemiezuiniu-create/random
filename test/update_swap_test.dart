import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:random_picker/core/update_applier.dart';

/// 交接脚本（apply.cmd）的**端到端演练**。
///
/// 这是整个自动更新里唯一「一旦写错就会把用户程序弄坏」的部分：它要在一个
/// 进程已经消失之后去覆盖那些文件。所以这里不满足于检查脚本文本，而是真的
/// 把脚本跑起来，看它有没有正确复制、正确回滚、正确清理自己。
///
/// ⚠️ 启动方式必须和真实程序一致：`ProcessStartMode.detached`。
/// 不能用 `Process.run` —— 它用管道捕获输出，而脚本里的 `start` 会让被启动的
/// 子进程继承那根管道，于是 Dart 永远等不到 EOF，测试直接挂死。
/// （这个坑我踩过一次，脚本本身没问题，是测试的启动方式错了。）
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rp_swap_');
  });

  tearDown(() async {
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 造一个「能启动、立刻退出」的假 exe：借用系统的 where.exe。
  /// 版本标记写在旁挂文件里，避免改 exe 字节。
  void makeFakeExe(String path, String version) {
    File(path).writeAsBytesSync(
      File(r'C:\Windows\System32\where.exe').readAsBytesSync(),
    );
    File('$path.version').writeAsStringSync(version);
  }

  /// 用和真实程序相同的方式启动脚本，并等它跑完（脚本末尾会删掉自己）。
  Future<void> runScriptDetached({
    required Directory install,
    required String stagingPath,
    required Directory backup,
    required Directory root,
  }) async {
    final script = File(p.join(root.path, 'apply.cmd'));
    await script.writeAsString(
      buildApplyScript(
        // 用一个不存在的 PID，让等待循环立刻进入复制阶段
        targetPid: 999999,
        stagingPath: stagingPath,
        installPath: install.path,
        backupPath: backup.path,
      ),
    );

    await Process.start(
      'cmd.exe',
      <String>['/c', script.path],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );

    // 脚本最后一步是 del "%~f0"，文件消失 == 全部跑完
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (script.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(script.existsSync(), isFalse,
        reason: '脚本没能跑完并删除自己（超时）');
  }

  test('正常路径：覆盖旧文件、把新文件带进来、清理现场', () async {
    final root = Directory(p.join(tmp.path, 'normal'))..createSync(recursive: true);
    final install = Directory(p.join(root.path, 'install'))..createSync(recursive: true);
    final staging = Directory(p.join(root.path, 'staging'))..createSync(recursive: true);
    final backup = Directory(p.join(root.path, 'backup'))..createSync(recursive: true);

    // 旧版本
    makeFakeExe(p.join(install.path, exeFileName), 'old');
    File(p.join(install.path, 'flutter_windows.dll')).writeAsStringSync('OLD-DLL');

    // 新版本（staging 就是解压后的内容）
    makeFakeExe(p.join(staging.path, exeFileName), 'new');
    File(p.join(staging.path, 'flutter_windows.dll')).writeAsStringSync('NEW-DLL');
    File(p.join(staging.path, 'brand_new.dll')).writeAsStringSync('ADDED');

    // 备份（模拟 UpdateApplier 已经做过）
    File(p.join(backup.path, exeFileName)).writeAsBytesSync(
      File(p.join(install.path, exeFileName)).readAsBytesSync(),
    );
    File(p.join(backup.path, 'flutter_windows.dll')).writeAsStringSync('OLD-DLL');

    await runScriptDetached(
      install: install,
      stagingPath: staging.path,
      backup: backup,
      root: root,
    );

    expect(
      File(p.join(install.path, '$exeFileName.version')).readAsStringSync(),
      'new',
      reason: '新 exe 应当已就位',
    );
    expect(
      File(p.join(install.path, 'flutter_windows.dll')).readAsStringSync(),
      'NEW-DLL',
      reason: '旧 DLL 应当被覆盖',
    );
    expect(
      File(p.join(install.path, 'brand_new.dll')).existsSync(),
      isTrue,
      reason: '新增的文件应当被复制进来',
    );
    expect(staging.existsSync(), isFalse, reason: '脚本应当清理掉 staging');
    expect(backup.existsSync(), isFalse, reason: '脚本应当清理掉 backup');
  });

  test('失败路径：覆盖失败时从备份回滚，程序不会变成半新半旧', () async {
    final root = Directory(p.join(tmp.path, 'rollback'))..createSync(recursive: true);
    final install = Directory(p.join(root.path, 'install'))..createSync(recursive: true);
    final backup = Directory(p.join(root.path, 'backup'))..createSync(recursive: true);

    // 备份里是完好的旧版本
    makeFakeExe(p.join(backup.path, exeFileName), 'backup-exe');
    File(p.join(backup.path, 'flutter_windows.dll')).writeAsStringSync('OLD-DLL');

    // 现场：模拟「上一次覆盖到一半」留下的破损状态
    File(p.join(install.path, exeFileName)).writeAsStringSync('HALF-WRITTEN-EXE');
    File(p.join(install.path, 'flutter_windows.dll')).writeAsStringSync('HALF-WRITTEN-DLL');

    await runScriptDetached(
      install: install,
      // staging 故意指向不存在的目录，强制 xcopy 失败
      stagingPath: p.join(root.path, 'staging-does-not-exist'),
      backup: backup,
      root: root,
    );

    expect(
      File(p.join(install.path, 'flutter_windows.dll')).readAsStringSync(),
      'OLD-DLL',
      reason: '应当从备份恢复，而不是留着半截文件',
    );
    expect(
      File(p.join(install.path, '$exeFileName.version')).readAsStringSync(),
      'backup-exe',
      reason: 'exe 也应当被恢复',
    );
  });
}
