import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/private_pub_host.dart';

void main() {
  for (final version in ['0.1.0', '3.4.5']) {
    test('private host binds SDK upload to explicit source version $version', () async {
      final root = Directory.systemTemp.createTempSync('pub-version-');
      addTearDown(() => root.deleteSync(recursive: true));
      final package = Directory(p.join(root.path, 'package'))..createSync();
      File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync(
        'name: archway\nversion: $version\ndescription: Private hosted version control.\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n',
      );
      File(p.join(package.path, 'README.md'))
          .writeAsStringSync('Private fixture');
      final upload = File(p.join(root.path, 'upload.tar.gz'));
      final result = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'publish',
        '--to-archive',
        upload.path,
        '--skip-validation',
      ], workingDirectory: package.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final cache = Directory(p.join(root.path, 'cache'))..createSync();
      final lock = File(p.join(root.path, 'pubspec.lock'))
        ..writeAsStringSync('packages: {}\n');
      final host = await PrivatePubHost.start(
        upload,
        cache,
        expectedVersion: version,
        dependencyLockfile: lock,
      );
      addTearDown(host.close);
      await expectLater(
        PrivatePubHost.start(
          upload,
          cache,
          expectedVersion: version == '0.1.0' ? '3.4.5' : '0.1.0',
          dependencyLockfile: lock,
        ),
        throwsFormatException,
      );
      await expectLater(
        PrivatePubHost.start(
          upload,
          cache,
          expectedVersion: '',
          dependencyLockfile: lock,
        ),
        throwsFormatException,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final metadata = jsonDecode(
        await (await (await client.getUrl(
          host.url.resolve('/api/packages/archway'),
        )).close()).transform(utf8.decoder).join(),
      ) as Map;
      expect(metadata['latest']['version'], version);
      final bytes = await (await (await client.getUrl(
        host.url.resolve('/archives/archway-$version.tar.gz'),
      )).close()).fold(<int>[], (all, part) => all..addAll(part));
      expect(sha256.convert(bytes), sha256.convert(upload.readAsBytesSync()));
    });
  }
}
