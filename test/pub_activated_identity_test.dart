import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/pub_activated_identity.dart';
import '../tool/release/archive_input.dart';

void main() {
  test(
    'activated SDK package identity decodes its URI and confines exact bytes',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('pub identity café-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final cache = Directory(p.join(root.path, 'cache'))..createSync();
      final package = Directory(
        p.join(cache.path, 'hosted', 'fixture host', 'archway-0.2.0'),
      );
      final entry = File(p.join(package.path, 'bin', 'archway.dart'))
        ..parent.createSync(recursive: true);
      final bytes = utf8.encode('independent fixture executable bytes');
      entry.writeAsBytesSync(bytes);
      final expected = ArchiveInventory({
        'bin/archway.dart': (
          size: bytes.length,
          mode: 420,
          sha256: sha256.convert(bytes).toString(),
        ),
      });
      final config = File(
        p.join(
          cache.path,
          'global_packages',
          'archway',
          '.dart_tool',
          'package_config.json',
        ),
      )..parent.createSync(recursive: true);
      void select(Directory directory) => config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'archway',
              'rootUri': directory.uri.toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      select(package);
      expect(
        (await inspectActivatedPubPackage(cache, expected)).path,
        package.path,
      );
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      select(outside);
      await expectLater(
        inspectActivatedPubPackage(cache, expected),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('outside its isolated hosted cache'),
          ),
        ),
      );
      if (!Platform.isWindows) {
        final alias = Link(p.join(cache.path, 'hosted', 'aliased package'))
          ..createSync(package.path);
        select(Directory(alias.path));
        await expectLater(
          inspectActivatedPubPackage(cache, expected),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('aliased or nonordinary'),
            ),
          ),
        );
      }
      select(package);
      entry.writeAsBytesSync(List<int>.filled(bytes.length, 120));
      await expectLater(
        inspectActivatedPubPackage(cache, expected),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Installation identity differs: bin/archway.dart'),
          ),
        ),
      );
    },
  );
}
