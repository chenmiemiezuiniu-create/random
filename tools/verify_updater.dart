// 更新检测的**真实联网**验证。
//
// lib/core/updater.dart 刻意不依赖 Flutter，所以可以脱离 flutter test 直接用
// dart 跑，打 GitHub 真实 API 验证整条链路：
//
//     dart run tools/verify_updater.dart
//
// 之所以不放进 test/ 目录：它会真的联网、会消耗 GitHub 未认证配额（60 次/小时），
// 放进测试套件会让 `flutter test` 变得依赖网络。这里作为手动验证工具保留。
import 'dart:io';

import 'package:random_picker/core/updater.dart';

var _pass = 0;
var _fail = 0;
final _failures = <String>[];

void check(String label, bool ok, [String extra = '']) {
  final suffix = extra.isEmpty ? '' : '  ($extra)';
  if (ok) {
    _pass++;
    stdout.writeln('  [OK]   $label$suffix');
  } else {
    _fail++;
    _failures.add(label);
    stdout.writeln('  [FAIL] $label$suffix');
  }
}

Future<void> main() async {
  stdout.writeln('== 离线：normalizeRepo（把各种写法归一成 owner/repo） ==');
  check('简写', normalizeRepo('a/b') == 'a/b');
  check('完整网址', normalizeRepo('https://github.com/a/b') == 'a/b');
  check('.git 后缀', normalizeRepo('https://github.com/a/b.git') == 'a/b');
  check('首尾多余空格与斜杠', normalizeRepo('  a/b/  ') == 'a/b');
  check('粘贴了子页面地址', normalizeRepo('https://github.com/a/b/releases') == 'a/b');
  check('ssh 写法', normalizeRepo('git@github.com:a/b.git') == 'a/b');

  stdout.writeln('');
  stdout.writeln('== 离线：compareVersions ==');
  check('1.0.1 > 1.0.0', compareVersions('1.0.1', '1.0.0') == 1);
  check('v 前缀不影响', compareVersions('v2.0', '1.9.9') == 1);
  check('按数字比较而非字符串', compareVersions('1.10.0', '1.9.0') == 1);
  check('位数不足补零', compareVersions('1', '1.0.0') == 0);
  check('预发布后缀被忽略', compareVersions('1.2.0-beta.1', '1.2.0') == 0);

  stdout.writeln('');
  stdout.writeln('== 联网：真实 GitHub Releases API ==');

  // 一个确实发过 Release、且附件里有 .exe 的公开仓库
  try {
    final info = await checkForUpdate(
      repo: 'microsoft/PowerToys',
      currentVersion: '0.0.1',
    );
    check('拿到最新版本号', info.latest.isNotEmpty, info.latest);
    check('判定为有新版本', info.hasUpdate);
    check('拿到更新说明', info.notes.isNotEmpty, '${info.notes.length} 字符');
    check('拿到安装包下载直链', info.downloadUrl != null, info.downloadUrl ?? 'null');
    check(
      '【回归】不会误挑 arm64 的包',
      info.downloadUrl != null &&
          !info.downloadUrl!.toLowerCase().contains('arm'),
      info.downloadUrl ?? 'null',
    );
    check(
      '拿到发布页地址',
      info.releaseUrl != null && info.releaseUrl!.contains('github.com'),
      info.releaseUrl ?? 'null',
    );
  } catch (e) {
    check('microsoft/PowerToys 检查更新', false, '$e');
  }

  // 没有任何发布附件的仓库：downloadUrl 允许为 null，但绝不能崩
  try {
    final info = await checkForUpdate(
      repo: 'flutter/flutter',
      currentVersion: '0.0.1',
    );
    check('无附件的仓库仍能拿到版本号', info.latest.isNotEmpty, info.latest);
    check('无附件时 downloadUrl 为 null 而不是抛异常', info.downloadUrl == null);
  } catch (e) {
    check('flutter/flutter 检查更新', false, '$e');
  }

  // 不存在的仓库：必须抛可读的 UpdateException，而不是崩溃
  try {
    await checkForUpdate(
      repo: 'dsh-nonexistent-user-xyz/no-such-repo',
      currentVersion: '1.0.0',
    );
    check('不存在的仓库应当抛异常', false, '居然没抛');
  } on UpdateException catch (e) {
    check('不存在的仓库抛出可读的 UpdateException',
        e.message.contains('读不到'), e.message.split('\n').first);
  } catch (e) {
    check('不存在的仓库抛 UpdateException', false, '抛的是 ${e.runtimeType}');
  }

  // 还没配置仓库：应该引导用户去设置里填，而不是报网络错误
  try {
    await checkForUpdate(repo: '', currentVersion: '1.0.0');
    check('空配置应当抛异常', false, '居然没抛');
  } on UpdateException catch (e) {
    check('空配置给出「去设置里填」的引导', e.message.contains('设置'));
  }

  stdout.writeln('');
  stdout.writeln('=' * 52);
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败清单：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
  }
  stdout.writeln('=' * 52);
  exit(_fail == 0 ? 0 : 1);
}
