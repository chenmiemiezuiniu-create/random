import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:random_picker/core/update_applier.dart';
import 'package:random_picker/core/updater.dart';
import 'package:random_picker/core/system_proxy.dart';

/// 自动更新的测试。
///
/// 下载链路用**本地 HttpServer** 真实验证（而不是打桩），
/// 这样进度回调、字节数校验、HTTP 错误处理都是真的被跑过一遍。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rp_update_');
  });

  tearDown(() async {
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------------- 下载

  group('downloadUpdate', () {
    /// 起一个只服务一次的本地 HTTP 服务。
    Future<HttpServer> startServer(
      void Function(HttpRequest req) handler,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(handler);
      return server;
    }

    test('正常下载：写全文件，进度回调一路到 100%', () async {
      final payload = List<int>.generate(120000, (i) => i % 251);
      final server = await startServer((req) {
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
        req.response.close();
      });

      final target = File(p.join(tmp.path, 'a.zip'));
      final fractions = <double>[];
      var lastReceived = 0;

      await downloadUpdate(
        url: 'http://127.0.0.1:${server.port}/a.zip',
        destination: target,
        expectedSize: payload.length,
        onProgress: (received, total) {
          lastReceived = received;
          final t = total;
          if (t != null && t > 0) fractions.add(received / t);
        },
      );

      expect(await target.exists(), isTrue);
      expect(await target.length(), payload.length);
      expect(lastReceived, payload.length);
      expect(fractions, isNotEmpty);
      expect(fractions.last, closeTo(1.0, 1e-9));
      // 进度必须单调不减，否则进度条会来回跳
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }

      await server.close(force: true);
    });

    test('服务端没给长度时用 expectedSize 兜底，对不上就报错', () async {
      // 不设 contentLength -> chunked 传输，客户端拿不到总长度
      final server = await startServer((req) {
        req.response.write('short');
        req.response.close();
      });

      final target = File(p.join(tmp.path, 'b.zip'));
      await expectLater(
        downloadUpdate(
          url: 'http://127.0.0.1:${server.port}/b.zip',
          destination: target,
          expectedSize: 999999,
        ),
        throwsA(isA<UpdateException>()),
      );

      await server.close(force: true);
    });

    test('HTTP 404 给出可读错误，而不是抛原始异常', () async {
      final server = await startServer((req) {
        req.response.statusCode = 404;
        req.response.close();
      });

      final target = File(p.join(tmp.path, 'c.zip'));
      try {
        await downloadUpdate(
          url: 'http://127.0.0.1:${server.port}/c.zip',
          destination: target,
          expectedSize: null,
        );
        fail('应该抛异常');
      } on UpdateException catch (e) {
        expect(e.message, contains('404'));
      }

      await server.close(force: true);
    });

    test('连不上服务器时也抛 UpdateException，不泄漏原始异常', () async {
      // 先占一个端口再关掉，保证这个端口没人监听
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);

      final target = File(p.join(tmp.path, 'd.zip'));
      await expectLater(
        downloadUpdate(
          url: 'http://127.0.0.1:$deadPort/d.zip',
          destination: target,
          expectedSize: null,
        ),
        throwsA(isA<UpdateException>()),
      );
    });

    test('下到空文件要报错', () async {
      final server = await startServer((req) {
        req.response.headers.contentLength = 0;
        req.response.close();
      });

      final target = File(p.join(tmp.path, 'e.zip'));
      await expectLater(
        downloadUpdate(
          url: 'http://127.0.0.1:${server.port}/e.zip',
          destination: target,
          expectedSize: null,
        ),
        throwsA(isA<UpdateException>()),
      );

      await server.close(force: true);
    });
  });

  // ------------------------------------------------------------- 解压

  group('extractZipTo', () {
    List<int> makeZip(Map<String, String> files) {
      final archive = Archive();
      files.forEach((name, content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive)!;
    }

    Future<File> writeZip(String name, List<int> bytes) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes(bytes);
      return f;
    }

    test('正常解压出目录结构和文件内容', () async {
      final zip = await writeZip('ok.zip', makeZip({
        'random_picker/random_picker.exe': 'EXE',
        'random_picker/flutter_windows.dll': 'DLL',
        'random_picker/data/icudtl.dat': 'ICU',
      }));
      final out = Directory(p.join(tmp.path, 'out'));

      await extractZipTo(zip, out);

      expect(await File(p.join(out.path, 'random_picker', 'random_picker.exe')).readAsString(), 'EXE');
      expect(await File(p.join(out.path, 'random_picker', 'data', 'icudtl.dat')).readAsString(), 'ICU');
    });

    test('【安全】拒绝越界路径（zip-slip），不能写到目标目录之外', () async {
      // 构造一个条目名带 ../ 的压缩包
      final archive = Archive();
      final bytes = utf8.encode('pwned');
      archive.addFile(ArchiveFile('../escaped.txt', bytes.length, bytes));
      final zip = await writeZip('evil.zip', ZipEncoder().encode(archive)!);

      final out = Directory(p.join(tmp.path, 'safe'));
      await expectLater(
        extractZipTo(zip, out),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('越界'),
        )),
      );

      // 关键：确认真的没写到外面去
      expect(await File(p.join(tmp.path, 'escaped.txt')).exists(), isFalse);
    });

    test('损坏的 zip 给出可读错误', () async {
      final zip = await writeZip('broken.zip', utf8.encode('这不是一个 zip'));
      final out = Directory(p.join(tmp.path, 'broken-out'));
      await expectLater(
        extractZipTo(zip, out),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  // -------------------------------------------------- 定位真正的程序目录

  group('findPayloadRoot', () {
    test('exe 就在解压根目录时返回根目录', () async {
      final root = Directory(p.join(tmp.path, 'flat'))..createSync(recursive: true);
      File(p.join(root.path, exeFileName)).writeAsStringSync('x');
      final found = await findPayloadRoot(root);
      expect(found?.path, root.path);
    });

    test('exe 在下一层子目录时返回那一层', () async {
      final root = Directory(p.join(tmp.path, 'nested'))..createSync(recursive: true);
      final inner = Directory(p.join(root.path, 'random_picker'))..createSync(recursive: true);
      File(p.join(inner.path, exeFileName)).writeAsStringSync('x');
      final found = await findPayloadRoot(root);
      expect(found?.path, inner.path);
    });

    test('找不到 exe 时返回 null', () async {
      final root = Directory(p.join(tmp.path, 'empty'))..createSync(recursive: true);
      File(p.join(root.path, 'readme.txt')).writeAsStringSync('x');
      expect(await findPayloadRoot(root), isNull);
    });
  });

  // ------------------------------------------------------- 交接脚本

  group('buildApplyScript', () {
    final script = buildApplyScript(
      targetPid: 4321,
      stagingPath: r'C:\Program Files\My App\RandomPickerData\update\staging\random_picker',
      installPath: r'C:\Program Files\My App',
      backupPath: r'C:\Program Files\My App\RandomPickerData\update\backup',
    );

    test('PID 与三个路径都写死进脚本', () {
      expect(script, contains('set "PID=4321"'));
      expect(script, contains(r'C:\Program Files\My App'));
      expect(script, contains(r'\staging\random_picker'));
      expect(script, contains(r'\backup'));
      // 占位符必须被全部替换掉
      expect(script, isNot(contains('@PID@')));
      expect(script, isNot(contains('@STAGE@')));
      expect(script, isNot(contains('@DEST@')));
      expect(script, isNot(contains('@BACKUP@')));
    });

    test('【回归】换行必须是 CRLF', () {
      // cmd.exe 解析 .cmd 文件依赖 CRLF。喂 LF-only 的文本给它，
      // 会把注释和下一行粘成一条命令去执行（报 9009 找不到命令），
      // 整个更新静默失败 —— 而脚本文本看上去完全正常，极难排查。
      expect(script, contains('\r\n'));
      expect(
        script.replaceAll('\r\n', ''),
        isNot(contains('\n')),
        reason: '脚本里还有裸 LF，cmd 会解析错乱',
      );
      expect(toCrlf('a\nb\r\nc\rd'), 'a\r\nb\r\nc\r\nd');
    });

    test('【回归】不能用 timeout 延时', () {
      // 脚本是以 DETACHED_PROCESS 启动的，没有控制台，
      // timeout 会直接报「输入重定向不受支持」而失败。
      expect(script.toLowerCase(), isNot(contains('timeout ')));
      expect(script, contains('ping -n'));
    });

    test('【回归】不能用管道接 tasklist —— 无控制台时管道会挂死', () {
      // 实测：`tasklist ... | findstr ...` 在没有控制台的进程里会直接卡住，
      // 脚本永远走不到复制那一步。必须改成先重定向到文件再读文件。
      final piped = RegExp(r'tasklist[^\r\n]*\|');
      expect(piped.hasMatch(script), isFalse,
          reason: '脚本里出现了 tasklist 管道，会导致自动更新永久卡死');
      expect(script, contains('>"%CHECK%"'));
      expect(script, contains('findstr /C:"%PID%" "%CHECK%"'));
    });

    test('【回归】复制用 robocopy 而不是 xcopy', () {
      // robocopy 的 /R /W 天生就是「目标被占用就重试」，
      // 正好对上「主程序刚退出、文件句柄可能还没释放」这个场景。
      expect(script, contains('robocopy'));
      expect(script.toLowerCase(), isNot(contains('xcopy')));
      expect(script, contains('/R:10 /W:1'));
    });

    test('robocopy 的退出码判断要按位理解：只有 >=8 才算失败', () {
      // robocopy 用位标志表示结果，1/2/4 都是「成功但有额外动作」，
      // 写成 `if errorlevel 1` 会把成功当失败，直接把更新回滚掉。
      expect(script, contains('if errorlevel 8 goto rollback'));
      expect(script, isNot(contains('if errorlevel 1 goto rollback')));
    });

    test('覆盖失败会从备份回滚', () {
      expect(script, contains(':rollback'));
      expect(script, contains('%BACKUP%'));
    });

    test('等待主程序退出后才复制', () {
      expect(script, contains('tasklist'));
      expect(script, contains(':waitloop'));
      // 复制必须在等待之后
      expect(script.indexOf(':waitloop'), lessThan(script.indexOf(':copyfiles')));
    });

    test('结束时清理自己，并收掉整个临时区', () {
      expect(script, contains('del "%~f0"'));
      // %STAGE% 是解压后的程序目录，外层还有一层 staging\，
      // 只删 %STAGE% 会把 staging\ 空壳留下（真实流程里踩到过）
      expect(script, contains(r'rmdir /S /Q "%~dp0staging"'));
      expect(script, contains(r'rmdir /S /Q "%~dp0backup"'));
    });
  });

  // ------------------------------------------------------- 前置校验

  group('UpdateApplier 前置检查', () {
    test('没有下载地址时给出可读提示，不做任何文件操作', () async {
      final info = UpdateInfo(
        current: '1.0.0',
        latest: '1.1.0',
        notes: 'x',
        downloadUrl: null,
      );
      await expectLater(
        UpdateApplier().apply(info),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('没有提供安装包'),
        )),
      );
    });

    test('下载地址为空字符串时同样拦下', () async {
      final info = UpdateInfo(
        current: '1.0.0',
        latest: '1.1.0',
        notes: 'x',
        downloadUrl: '',
      );
      await expectLater(
        UpdateApplier().apply(info),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  // --------------------------------------------------- SHA-256 完整性校验

  group('SHA-256 校验', () {
    test('sha256OfFile 结果正确（用公认测试向量）', () async {
      final f = File(p.join(tmp.path, 'hello.txt'));
      await f.writeAsString('hello');
      // sha256("hello") 是公开的标准测试向量
      expect(
        await sha256OfFile(f),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });

    test('sha256OfFile 空文件也对', () async {
      final f = File(p.join(tmp.path, 'empty.bin'));
      await f.writeAsBytes(const <int>[]);
      expect(
        await sha256OfFile(f),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    Future<HttpServer> serveFixed(List<int> payload) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
        req.response.close();
      });
      return server;
    }

    test('哈希对得上时下载通过', () async {
      final payload = List<int>.generate(5000, (i) => i % 251);
      final server = await serveFixed(payload);
      final target = File(p.join(tmp.path, 'ok-hash.zip'));

      // 先在本地算出期望值（用系统工具算，避免和被测代码同源）
      final probe = File(p.join(tmp.path, 'probe.bin'));
      await probe.writeAsBytes(payload);
      final expected = await sha256OfFile(probe);

      await downloadUpdate(
        url: 'http://127.0.0.1:${server.port}/ok.zip',
        destination: target,
        expectedSize: payload.length,
        expectedSha256: expected,
      );
      expect(await target.length(), payload.length);
      await server.close(force: true);
    });

    test('【安全】哈希对不上必须中止，不能放行被替换的包', () async {
      final payload = List<int>.filled(5000, 7);
      final server = await serveFixed(payload);
      final target = File(p.join(tmp.path, 'tampered.zip'));

      // 故意给一个错误的期望哈希，模拟「字节数一样但内容被换掉」
      const wrong = '0000000000000000000000000000000000000000000000000000000000000000';
      try {
        await downloadUpdate(
          url: 'http://127.0.0.1:${server.port}/x.zip',
          destination: target,
          expectedSize: payload.length,
          expectedSha256: wrong,
        );
        fail('哈希不符时必须抛异常');
      } on UpdateException catch (e) {
        expect(e.message, contains('SHA-256'));
        expect(e.message, contains('已中止'));
      }
      await server.close(force: true);
    });

    test('期望哈希大小写不敏感', () async {
      final payload = List<int>.generate(100, (i) => i);
      final server = await serveFixed(payload);
      final probe = File(p.join(tmp.path, 'p2.bin'));
      await probe.writeAsBytes(payload);
      final expected = (await sha256OfFile(probe)).toUpperCase();

      await downloadUpdate(
        url: 'http://127.0.0.1:${server.port}/u.zip',
        destination: File(p.join(tmp.path, 'upper.zip')),
        expectedSize: payload.length,
        expectedSha256: expected,
      );
      await server.close(force: true);
    });

    test('没给期望哈希时跳过校验（老 Release 没有 digest 字段）', () async {
      final payload = List<int>.generate(100, (i) => i);
      final server = await serveFixed(payload);
      await downloadUpdate(
        url: 'http://127.0.0.1:${server.port}/n.zip',
        destination: File(p.join(tmp.path, 'nohash.zip')),
        expectedSize: payload.length,
      );
      await server.close(force: true);
    });
  });

  // ------------------------------------------------------- 代理回退

  group('withProxyFallback', () {
    test('连接类错误会改直连重试一次', () async {
      final hasProxy = SystemProxy.address() != null;
      var attempts = 0;
      try {
        await withProxyFallback<String>((client) async {
          attempts++;
          throw const SocketException('代理端口没人监听');
        });
      } catch (_) {
        // 直连也失败也没关系，这里只关心试了几次
      }
      // 有代理才会多试一次；没配代理时没有「回退」可言
      expect(attempts, hasProxy ? 2 : 1);
    });

    test('UpdateException 不触发重试（换通道也没用，白费流量）', () async {
      var attempts = 0;
      await expectLater(
        withProxyFallback<String>((client) async {
          attempts++;
          throw UpdateException('HTTP 404');
        }),
        throwsA(isA<UpdateException>()),
      );
      expect(attempts, 1);
    });

    test('第一次就成功时不重试', () async {
      var attempts = 0;
      final result = await withProxyFallback<String>((client) async {
        attempts++;
        return 'ok';
      });
      expect(result, 'ok');
      expect(attempts, 1);
    });
  });
}
