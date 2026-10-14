import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/loopback_tls.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late File certificate;
  final requests = <String>[];
  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('npm https café ')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final tls = await createLoopbackTls(root);
    final context = tls.context;
    certificate = tls.certificate;
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    addTearDown(() => server.close(force: true));
    requests.clear();
    server.listen((request) async {
      requests.add(request.uri.path);
      final response = request.response;
      if (request.uri.path == '/stall') {
        response.bufferOutput = false;
        response.add([1]);
        await response.flush();
        return;
      }
      if (['/redirect', '/loop', '/downgrade'].contains(request.uri.path)) {
        response.statusCode = 302;
        response.headers.set(
          'location',
          request.uri.path == '/redirect'
              ? '/payload'
              : request.uri.path == '/loop'
              ? '/loop'
              : 'http://127.0.0.1:${server.port}/payload',
        );
      } else if (request.uri.path == '/missing') {
        response.statusCode = 404;
      } else if (request.uri.path == '/short') {
        response.add([1, 2]);
      } else if (request.uri.path == '/long') {
        response.add([1, 2, 3, 4, 5]);
      } else if (request.uri.path == '/length') {
        response.contentLength = 5;
        response.add([1, 2, 3, 4, 5]);
      } else {
        response.add([1, 2, 3, 4]);
      }
      await response.close();
    });
  });
  Future<ProcessResult> download(String route, {int timeout = 120000}) =>
      Process.run(
        Platform.environment['ARCHWAY_TEST_NODE'] ?? 'node',
        [
          '-e',
          "require(process.argv[1]).downloadNativeArchive(new URL(process.argv[2]),process.argv[3],4,Number(process.argv[4])).catch(e=>{console.error(e.message);process.exitCode=126;});",
          p.absolute('tool/npm/download.cjs'),
          'https://127.0.0.1:${server.port}/$route',
          p.join(root.path, 'archive'),
          '$timeout',
        ],
        environment: {'NODE_EXTRA_CA_CERTS': certificate.path},
      );
  test('HTTPS redirects retain exact bytes and emit no progress', () async {
    final result = await download('redirect');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, isEmpty);
    expect(result.stderr, isEmpty);
    expect(File(p.join(root.path, 'archive')).readAsBytesSync(), [1, 2, 3, 4]);
    expect(requests, ['/redirect', '/payload']);
  });
  test('HTTPS rejects downgrade, redirects and framed size failures', () async {
    for (final (route, diagnostic, count) in [
      ('downgrade', 'requires HTTPS', 1),
      ('loop', 'redirect limit', 6),
      ('short', 'size differs', 1),
      ('long', 'exceeds pinned size', 1),
      ('length', 'declared size differs', 1),
      ('missing', 'HTTP 404', 1),
    ]) {
      requests.clear();
      final result = await download(route);
      expect(result.exitCode, 126, reason: route);
      expect(result.stderr, contains(diagnostic), reason: route);
      expect(result.stdout, isEmpty);
      expect(requests, List.filled(count, '/$route'));
      expect(File(p.join(root.path, 'archive')).existsSync(), isFalse);
    }
  });
  test(
    'elapsed transfer budget removes an observed partial file and closes it',
    () async {
      final pending = download('stall', timeout: 1000);
      final file = File(p.join(root.path, 'archive'));
      final watch = Stopwatch()..start();
      while ((!file.existsSync() || file.lengthSync() != 1) &&
          watch.elapsedMilliseconds < 800) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), [1]);
      final result = await pending;
      expect(result.exitCode, 126);
      expect(result.stderr, contains('timed out'));
      expect(file.existsSync(), isFalse);
      file.writeAsStringSync('reusable');
      expect(requests, ['/stall']);
    },
  );
  test('existing download destination remains unchanged', () async {
    final file = File(p.join(root.path, 'archive'))..writeAsStringSync('keep');
    final result = await download('payload');
    expect(result.exitCode, 126);
    expect(result.stderr, contains('EEXIST'));
    expect(file.readAsStringSync(), 'keep');
  });
}
