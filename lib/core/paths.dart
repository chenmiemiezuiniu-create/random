import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'constants.dart';

/// 数据目录。
///
/// 设计目标：**便携 + 零残留**。
///
/// * Windows / Linux / macOS：数据放在可执行文件同级目录的
///   `RandomPickerData/` 里。用户把整个文件夹删掉就什么都不剩，
///   绝不会往 C 盘用户目录偷偷写东西。
/// * Android / iOS：没有「同级目录」这个概念，只能放应用私有目录，
///   系统会在卸载时自动清除，同样零残留。
class AppPaths {
  static Directory? _cached;

  static Future<Directory> dataDir() async {
    final cached = _cached;
    if (cached != null) return cached;

    Directory dir;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // resolvedExecutable 在发布版里就是 exe 自己的完整路径。
      final exeDir = File(Platform.resolvedExecutable).parent;
      dir = Directory(p.join(exeDir.path, kDataFolderName));
    } else {
      final base = await getApplicationSupportDirectory();
      dir = Directory(p.join(base.path, kDataFolderName));
    }

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cached = dir;
    return dir;
  }

  static Future<File> dataFile(String name) async {
    final dir = await dataDir();
    return File(p.join(dir.path, name));
  }

  /// 数据目录是否可写。装在 Program Files 里时可能不可写，需要提示用户。
  static Future<bool> isWritable() async {
    try {
      final dir = await dataDir();
      final probe = File(p.join(dir.path, '.write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 单元测试用：把数据目录指向临时目录，避免污染真实运行目录。
  static void overrideDataDirForTesting(Directory dir) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cached = dir;
  }

  /// 单元测试用：清掉缓存，恢复正常推导。
  static void resetForTesting() {
    _cached = null;
  }
}
