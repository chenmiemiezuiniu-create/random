import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'constants.dart';
import 'paths.dart';
import 'updater.dart';

/// 主程序文件名。安装包解压后靠它定位真正的程序目录。
const String exeFileName = 'random_picker.exe';

/// 下载下来的压缩包暂存名。
const String _zipName = 'pending.zip';

/// 自动更新的阶段，用来驱动界面上的进度提示。
enum UpdateStage {
  downloading('正在下载更新'),
  extracting('正在解压'),
  preparing('正在准备替换'),
  launching('即将自动重启');

  const UpdateStage(this.label);

  final String label;
}

class UpdateProgress {
  const UpdateProgress(this.stage, {this.received = 0, this.total});

  final UpdateStage stage;
  final int received;

  /// 拿不到总长度时为 null，界面应退化成不确定进度条。
  final int? total;

  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// 自动更新器：下载 → 解压 → 备份 → 交接给外部脚本 → 由调用方退出程序。
///
/// ## 为什么必须交给外部脚本
///
/// Windows 会锁住正在运行的 `.exe`，**程序无法覆盖自己**。所以这里把新版本
/// 先铺到 `RandomPickerData\update\staging\`，生成一个 `apply.cmd`，
/// 用「完全脱离」的方式启动它，然后主程序退出。脚本等主程序真的退出后
/// 才执行覆盖、启动新版、清理自己。
///
/// ## 为什么要备份
///
/// 覆盖到一半失败（断电、被杀软中断、磁盘满）会留下一个半新半旧、
/// 起不来的程序。所以覆盖前先把现有文件备份到 `update\backup\`，
/// 脚本一旦发现 xcopy 失败就用备份原样恢复。
/// 安全解压 zip 到 [target]。
///
/// 会拒绝越界路径（zip-slip）：条目名里带 `../` 想写到目标目录之外时直接中止，
/// 否则一个恶意/损坏的压缩包就能往系统任意位置写文件。
///
/// 公开而非私有：`test/logic_test.dart` 用合成压缩包覆盖这条规则。
Future<void> extractZipTo(File zip, Directory target) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
  } catch (e) {
    throw UpdateException('安装包解压失败，文件可能已损坏：$e');
  }

  final root = p.normalize(target.absolute.path);
  for (final entry in archive) {
    final outPath = p.normalize(p.join(root, entry.name));
    if (!p.isWithin(root, outPath)) {
      throw UpdateException('安装包内容异常（含越界路径 ${entry.name}），已中止更新。');
    }
    if (entry.isFile) {
      final file = File(outPath);
      await file.parent.create(recursive: true);
      final content = entry.content;
      await file.writeAsBytes(content is List<int> ? content : const <int>[]);
    } else {
      await Directory(outPath).create(recursive: true);
    }
  }
}

/// 压缩包顶层通常有一层 `random_picker/`，找出真正放 exe 的那一层。
Future<Directory?> findPayloadRoot(
  Directory staging, {
  String exeName = exeFileName,
}) async {
  if (await File(p.join(staging.path, exeName)).exists()) return staging;

  await for (final entity in staging.list(followLinks: false)) {
    if (entity is Directory &&
        await File(p.join(entity.path, exeName)).exists()) {
      return entity;
    }
  }
  return null;
}

/// 生成交接脚本。
///
/// 路径**直接写进脚本正文**，不走 `cmd /c` 的参数传递 ——
/// cmd 对带空格路径的引号解析非常容易出错，写死最稳。
///
/// ⚠️ 换行**必须归一成 CRLF**。cmd.exe 解析 .cmd 文件时依赖 CRLF，
/// 喂给它 LF-only 的文本会把注释和下一行粘成一条命令去执行，
/// 报出「'xxx' 不是内部或外部命令」(9009)，整个更新静默失败。
/// 这个坑极难查：脚本文本看上去完全正常。
String buildApplyScript({
  required int targetPid,
  required String stagingPath,
  required String installPath,
  required String backupPath,
}) {
  final text = _scriptTemplate
      .replaceAll('@PID@', '$targetPid')
      .replaceAll('@STAGE@', stagingPath)
      .replaceAll('@DEST@', installPath)
      .replaceAll('@BACKUP@', backupPath);
  return toCrlf(text);
}

/// 把任意换行归一成 CRLF。
String toCrlf(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', '\r\n');

class UpdateApplier {
  UpdateApplier({this.onProgress});

  final void Function(UpdateProgress progress)? onProgress;

  void _report(UpdateStage stage, {int received = 0, int? total}) {
    onProgress?.call(UpdateProgress(stage, received: received, total: total));
  }

  /// 执行更新。**成功返回后调用方应当立即 `exit(0)`**，
  /// 否则外部脚本会一直等着我们退出，替换永远不会发生。
  ///
  /// [installDirOverride] 只给测试用：默认拿 `resolvedExecutable` 所在目录，
  /// 而在 `flutter test` 里那是 Dart SDK 的 bin 目录 —— 真去备份/覆盖它
  /// 会把 SDK 弄坏，所以测试必须显式指定一个临时目录。
  Future<void> apply(UpdateInfo info, {Directory? installDirOverride}) async {
    if (!Platform.isWindows) {
      throw UpdateException('自动更新目前只支持 Windows，其它平台请手动下载。');
    }
    final url = info.downloadUrl;
    if (url == null || url.isEmpty) {
      throw UpdateException('这个版本没有提供安装包，请到发布页手动下载。');
    }

    final installDir = installDirOverride ?? File(Platform.resolvedExecutable).parent;
    if (!await _isWritable(installDir)) {
      throw UpdateException(
        '程序所在的文件夹不可写，没法自动替换：\n${installDir.path}\n\n'
        '如果它放在 Program Files 之类的位置，请移到桌面或 U 盘后再更新，'
        '或者到发布页手动下载。',
      );
    }

    final dataDir = await AppPaths.dataDir();
    final updateDir = Directory(p.join(dataDir.path, 'update'));
    final zipFile = File(p.join(updateDir.path, _zipName));
    final staging = Directory(p.join(updateDir.path, 'staging'));
    final backup = Directory(p.join(updateDir.path, 'backup'));

    // 每次更新都从干净状态开始，避免上次的残留干扰
    if (await updateDir.exists()) {
      await _deleteQuietly(updateDir);
    }
    await staging.create(recursive: true);

    _report(UpdateStage.downloading, total: info.downloadSize);
    // 包一层代理回退：代理软件被关掉但注册表还留着开启状态时，自动改直连重试
    await withProxyFallback((client) {
      return downloadUpdate(
        url: url,
        destination: zipFile,
        expectedSize: info.downloadSize,
        expectedSha256: info.downloadSha256,
        client: client,
        onProgress: (received, total) => _report(
          UpdateStage.downloading,
          received: received,
          total: total,
        ),
      );
    });

    _report(UpdateStage.extracting);
    await extractZipTo(zipFile, staging);
    await _deleteQuietly(zipFile);

    final payload = await findPayloadRoot(staging);
    if (payload == null) {
      throw UpdateException('安装包里没找到 $exeFileName，下载的文件可能不对。');
    }

    _report(UpdateStage.preparing);
    await _backupInstall(installDir, backup);

    final script = File(p.join(updateDir.path, 'apply.cmd'));
    await script.writeAsString(
      buildApplyScript(
        targetPid: pid,
        stagingPath: payload.path,
        installPath: installDir.path,
        backupPath: backup.path,
      ),
      flush: true,
    );

    _report(UpdateStage.launching);
    await Process.start(
      'cmd.exe',
      <String>['/c', script.path],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  // ------------------------------------------------------------- 内部实现

  Future<bool> _isWritable(Directory dir) async {
    try {
      final probe = File(p.join(dir.path, '.write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (_) {
      // 删不掉就留着，不影响后续流程
    }
  }

  /// 备份安装目录（**排除用户数据**），用于覆盖失败时回滚。
  Future<void> _backupInstall(Directory install, Directory backup) async {
    await backup.create(recursive: true);
    await for (final entity in install.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name == kDataFolderName) continue; // 用户名单不备份、也绝不覆盖
      if (entity is File) {
        await entity.copy(p.join(backup.path, name));
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(backup.path, name)));
      }
    }
  }

  Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File) {
        await entity.copy(p.join(to.path, name));
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(to.path, name)));
      }
    }
  }
}

/// 交接脚本。
///
/// 三条约束都是实测踩出来的，改脚本前务必先看：
///
/// 1. **不能用 `timeout` 延时**。主程序是用 DETACHED_PROCESS 启动本脚本的，
///    这种进程没有控制台，`timeout` 会直接报「输入重定向不受支持」而失败。
///    统一改用 `ping 127.0.0.1` 等待。
/// 2. **不能用管道接 `tasklist`**（`tasklist ... | findstr ...`）。
///    实测在无控制台的进程里这种管道会直接挂死，脚本永远走不下去。
///    改成先重定向到文件，再让 findstr 读文件。
/// 3. **复制用 `robocopy` 而不是 `xcopy`**。robocopy 的 `/R` `/W` 天生就是
///    「目标被占用就等待重试」，正好对上「主程序刚退出、句柄可能还没释放」
///    这个场景；xcopy 不会重试。注意 robocopy 的退出码**按位表示结果，
///    0~7 都算成功**，只有 ≥8 才是真失败，所以判断要写 `if errorlevel 8`。
const String _scriptTemplate = r'''
@echo off
setlocal EnableExtensions
set "PID=@PID@"
set "STAGE=@STAGE@"
set "DEST=@DEST@"
set "BACKUP=@BACKUP@"
set "CHECK=%~dp0pidcheck.tmp"

rem ---- 等主程序真的退出（最多约 60 秒），否则 exe 还被锁着 ----
set /a WAITED=0
:waitloop
tasklist /FI "PID eq %PID%" /NH >"%CHECK%" 2>nul
findstr /C:"%PID%" "%CHECK%" >nul
if errorlevel 1 goto copyfiles
set /a WAITED+=1
if %WAITED% GEQ 60 goto copyfiles
ping -n 2 127.0.0.1 >nul
goto waitloop

:copyfiles
del "%CHECK%" >nul 2>&1
rem 再等一拍，让文件锁彻底释放
ping -n 2 127.0.0.1 >nul

rem /R:10 /W:1 = 文件被占用时最多重试 10 次、每次等 1 秒
robocopy "%STAGE%" "%DEST%" /E /IS /IT /R:10 /W:1 /NFL /NDL /NJH /NJS /NP >nul 2>&1
if errorlevel 8 goto rollback

start "" "%DEST%\random_picker.exe"
goto cleanup

:rollback
rem 覆盖失败：用备份原样恢复，保证程序还能起来
robocopy "%BACKUP%" "%DEST%" /E /IS /IT /R:10 /W:1 /NFL /NDL /NJH /NJS /NP >nul 2>&1
start "" "%DEST%\random_picker.exe"
goto cleanup

:cleanup
ping -n 5 127.0.0.1 >nul
rem %STAGE% 是解压后的程序目录（压缩包通常还有一层顶层目录，
rem 所以它是 update\staging\random_picker），只删它会把外层 staging\ 留下。
rem 这里连本次更新的整个临时区一起收掉。
rmdir /S /Q "%STAGE%" >nul 2>&1
rmdir /S /Q "%~dp0staging" >nul 2>&1
rmdir /S /Q "%~dp0backup" >nul 2>&1
del "%~f0" >nul 2>&1
exit /b 0
''';
