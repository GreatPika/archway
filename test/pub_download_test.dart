import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/loopback_tls.dart';

import '../tool/pub/download.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late SecurityContext trusted;
  late Uri base;
  final requests = <String>[];
  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('pub-download café-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final tls = await createLoopbackTls(root);
    final context = tls.context;
    trusted = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(tls.certificate.path);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    base = Uri.parse('https://127.0.0.1:${server.port}/');
    addTearDown(() => server.close(force: true));
    requests.clear();
    server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path == '/stall') {
        request.response.add([1]);
        await request.response.flush();
        return;
      }
      if (request.uri.path == '/downgrade' || request.uri.path == '/loop') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          request.uri.path == '/loop'
              ? '/loop'
              : 'http://127.0.0.1:${server.port}/payload',
        );
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/payload');
      } else if (request.uri.path == '/short') {
        request.response.add([1, 2]);
      } else if (request.uri.path == '/long') {
        request.response.add([1, 2, 3, 4, 5]);
      } else if (request.uri.path == '/length') {
        request.response.contentLength = 5;
        request.response.add([1, 2, 3, 4, 5]);
      } else if (request.uri.path == '/missing') {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
  });
  test(
    'HTTPS redirect preserves exact bytes with a usable destination',
    () async {
      final output = File(p.join(root.path, 'archive'));
      await downloadNativeArchive(
        base.resolve('redirect'),
        output,
        4,
        client: HttpClient(context: trusted),
      );
      expect(output.readAsBytesSync(), [1, 2, 3, 4]);
      expect(requests, ['/redirect', '/payload']);
      output.renameSync(p.join(root.path, 'closed'));
    },
  );
  test(
    'refuses downgrade and bounded redirect loops without payload requests',
    () async {
      for (final (path, count) in [('downgrade', 1), ('loop', 6)]) {
        requests.clear();
        final output = File(p.join(root.path, path));
        await expectLater(
          downloadNativeArchive(
            base.resolve(path),
            output,
            4,
            client: HttpClient(context: trusted),
          ),
          throwsFormatException,
        );
        expect(requests, List.filled(count, '/$path'));
        expect(output.existsSync(), isFalse);
      }
    },
  );
  test(
    'rejects declared and streamed size failures and removes partial bytes',
    () async {
      for (final (path, diagnostic) in [
        ('length', 'size differs'),
        ('long', 'exceeds pinned size'),
        ('short', 'size differs'),
      ]) {
        final output = File(p.join(root.path, path));
        await expectLater(
          downloadNativeArchive(
            base.resolve(path),
            output,
            4,
            client: HttpClient(context: trusted),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'diagnostic',
              contains(diagnostic),
            ),
          ),
        );
        expect(output.existsSync(), isFalse, reason: path);
      }
    },
  );
  test('HTTP refusal and stalled body cannot leave a candidate', () async {
    final missing = File(p.join(root.path, 'missing'));
    await expectLater(
      downloadNativeArchive(
        base.resolve('missing'),
        missing,
        4,
        client: HttpClient(context: trusted),
      ),
      throwsA(isA<HttpException>()),
    );
    expect(missing.existsSync(), isFalse);
    final stalled = File(p.join(root.path, 'stall'));
    await expectLater(
      downloadNativeArchive(
        base.resolve('stall'),
        stalled,
        4,
        client: HttpClient(context: trusted),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(requests, ['/missing', '/stall']);
    expect(stalled.existsSync(), isFalse);
  });
  test('existing destination is preserved without making a request', () async {
    final output = File(p.join(root.path, 'existing'))..writeAsBytesSync([9]);
    final client = HttpClient(context: trusted);
    try {
      await expectLater(
        downloadNativeArchive(
          base.resolve('payload'),
          output,
          4,
          client: client,
        ),
        throwsFormatException,
      );
    } finally {
      client.close(force: true);
    }
    expect(requests, isEmpty);
    expect(output.readAsBytesSync(), [9]);
  });
}
