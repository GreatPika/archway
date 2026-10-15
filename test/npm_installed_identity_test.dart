import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/npm/installed_identity.dart';

void main() {
  late Directory root;
  late File archive;
  late Map<String, Object?> receipt;
  void save() =>
      File(p.join(root.path, 'npm-packed.json'))
          .writeAsStringSync(jsonEncode(receipt));
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('npm-packed-identity-')
          .resolveSymbolicLinksSync(),
    );
    archive = File(p.join(root.path, 'archway-architecture-cli-0.2.0.tgz'))
      ..writeAsStringSync('packed fixture');
    receipt = {
      'schema_version': 1,
      'version': '0.2.0',
      'source': {'commit': 'a' * 40},
      'descriptor_sha256': 'b' * 64,
      'stage_inventory_sha256': 'c' * 64,
      'registry_ready': false,
      'filename': p.basename(archive.path),
      'compressed_bytes': archive.lengthSync(),
      'sha256': sha256.convert(archive.readAsBytesSync()).toString(),
    };
    save();
  });
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'packed admission supplies a pinned owned archive for the whole callback',
    () async {
      late String owned;
      await withNpmPackedCandidate(
        root,
        expectedCommit: 'a' * 40,
        registryReady: false,
        inspect: (snapshot, observed) async {
          owned = snapshot.path;
          expect(p.basename(owned), p.basename(archive.path));
          expect(owned, isNot(archive.path));
          archive.writeAsStringSync('changed after admission');
          expect(snapshot.readAsStringSync(), 'packed fixture');
          expect(observed, receipt);
        },
      );
      expect(File(owned).existsSync(), isFalse);
    },
  );
  test(
    'packed byte and caller identity refusals precede installation callback',
    () async {
      var called = false;
      Future<void> inspect(File _, Map<String, Object?> __) async {
        called = true;
      }

      await expectLater(
        withNpmPackedCandidate(
          root,
          expectedCommit: 'd' * 40,
          registryReady: false,
          inspect: inspect,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('packed npm identity'),
          ),
        ),
      );
      await expectLater(
        withNpmPackedCandidate(
          root,
          expectedCommit: 'a' * 40,
          registryReady: true,
          inspect: inspect,
        ),
        throwsA(isA<FormatException>()),
      );
      archive.writeAsStringSync(
        'packed fixturf',
      ); // Same length, distinct bytes.
      await expectLater(
        withNpmPackedCandidate(
          root,
          expectedCommit: 'a' * 40,
          registryReady: false,
          inspect: inspect,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('identity'),
          ),
        ),
      );
      expect(called, isFalse);
    },
  );
  test(
    'cache evidence binds publication record manifest and executable pins',
    () async {
      final wrapper = Directory(p.join(root.path, 'wrapper'))..createSync();
      final cache = Directory(p.join(root.path, 'cache'))..createSync();
      final parent = Directory(p.join(cache.path, '0.2.0', 'linux-x64'))
        ..createSync(recursive: true);
      const leaf = '.archway-native-01234567-89ab-cdef-0123-456789abcdef';
      final payload = Directory(p.join(parent.path, leaf))..createSync();
      final executable = File(p.join(payload.path, 'bin/linux-x64/archway'))
        ..parent.createSync(recursive: true);
      executable.writeAsStringSync('executable fixture');
      final manifest = File(p.join(payload.path, 'manifest.json'))
        ..writeAsStringSync(
          jsonEncode({
            'schema_version': 1,
            'version': '0.2.0',
            'target': 'linux-x64',
            'source': receipt['source'],
            'files': {
              'bin/linux-x64/archway': {
                'size': executable.lengthSync(),
                'mode': 493,
                'sha256': sha256
                    .convert(executable.readAsBytesSync())
                    .toString(),
              },
            },
          }),
        );
      final descriptor = File(p.join(wrapper.path, 'acquisition.json'))
        ..writeAsStringSync(
          jsonEncode({
            'schema_version': 1,
            'version': '0.2.0',
            'source': receipt['source'],
            'targets': {
              'linux-x64': {
                'sha256': 'e' * 64,
                'manifest_sha256': sha256
                    .convert(manifest.readAsBytesSync())
                    .toString(),
              },
            },
          }),
        );
      receipt['descriptor_sha256'] = sha256
          .convert(descriptor.readAsBytesSync())
          .toString();
      File(p.join(wrapper.path, 'package.json')).writeAsStringSync(
        '{"name":"archway-architecture-cli","version":"0.2.0","private":true}',
      );
      final record = File(p.join(parent.path, 'e' * 64))
        ..writeAsStringSync('$leaf\n');
      Future<dynamic> inspect() => inspectNpmNativeCache(
        wrapper: wrapper,
        cache: cache,
        target: 'linux-x64',
        receipt: receipt,
      );
      expect((await inspect()).payload.path, payload.path);
      record.writeAsStringSync('../outside\n');
      await expectLater(
        inspect(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('publication record'),
          ),
        ),
      );
      record.writeAsStringSync('$leaf\n');
      final original = manifest.readAsBytesSync();
      manifest.writeAsStringSync('${utf8.decode(original)} ');
      await expectLater(
        inspect(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('manifest differs'),
          ),
        ),
      );
      manifest.writeAsBytesSync(original);
      executable.writeAsStringSync('executable fixturf');
      await expectLater(
        inspect(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('identity'),
          ),
        ),
      );
    },
  );
}
