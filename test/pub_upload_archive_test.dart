import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/gzip_input.dart';
import '../tool/release/tar_input.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('pub upload café-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'real SDK export directory dialect verifies and extracts exact files',
    () async {
      final source = Directory(p.join(root.path, 'source'))..createSync();
      final data = {
        'pubspec.yaml': utf8.encode(
          'name: archway_upload_fixture\nversion: 0.2.0\nenvironment:\n  sdk: ">=3.13.3 <4.0.0"\n',
        ),
        'bin/archway.dart': utf8.encode('void main() {}\n'),
      };
      for (final entry in data.entries) {
        final file = File(p.join(source.path, entry.key));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value);
      }
      final archive = File(p.join(root.path, 'sdk.tar.gz'));
      // This is a codec dialect proof, deliberately not package-validation evidence.
      final result = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'publish',
        '--directory',
        source.path,
        '--to-archive',
        archive.path,
        '--skip-validation',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final expected = ArchiveInventory({
        for (final entry in data.entries)
          entry.key: (
            size: entry.value.length,
            mode: 420,
            sha256: sha256.convert(entry.value).toString(),
          ),
      });
      await withArchiveInput(
        archive,
        (compressed) => withGzipSnapshot(
          compressed,
          (expanded) => withArchiveInput(expanded, (input) async {
            await expectLater(
              verifyTarInput(input, expected),
              throwsFormatException,
            );
            await withTarExtraction(input, expected, (directory) async {
              expect(
                directory
                    .listSync(recursive: true)
                    .whereType<File>()
                    .map(
                      (file) => p
                          .relative(file.path, from: directory.path)
                          .split(p.separator)
                          .join('/'),
                    )
                    .toSet(),
                data.keys.toSet(),
              );
              for (final entry in data.entries) {
                expect(
                  File(p.join(directory.path, entry.key)).readAsBytesSync(),
                  entry.value,
                );
              }
            }, dialect: TarDialect.pubUpload);
          }),
        ),
      );
    },
  );
  test(
    'pub directory and file duplicates reject matching legitimate bytes',
    () async {
      final bytes = [1, 2, 3];
      final expected = ArchiveInventory({
        'a/b.txt': (
          size: 3,
          mode: 420,
          sha256: sha256.convert(bytes).toString(),
        ),
      });
      TarEntry directory() => TarEntry.data(
        TarHeader(name: 'a', mode: 493, typeFlag: TypeFlag.dir),
        [],
      );
      TarEntry file() =>
          TarEntry.data(TarHeader(name: 'a/b.txt', mode: 420), bytes);
      for (final entries in [
        [directory(), directory(), file()],
        [directory(), file(), file()],
      ]) {
        final archive = File(p.join(root.path, 'duplicate.tar'));
        await Stream<TarEntry>.fromIterable(entries)
            .transform(tarWriter)
            .pipe(archive.openWrite());
        await withArchiveInput(archive, (input) async {
          var called = false;
          await expectLater(
            withTarExtraction(input, expected, (_) async {
              called = true;
            }, dialect: TarDialect.pubUpload),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'diagnostic',
                contains('Duplicate'),
              ),
            ),
          );
          expect(called, isFalse);
        });
      }
    },
  );
  test(
    'pub declared size is bound independently of matching content digest',
    () async {
      final bytes = [1, 2, 3];
      final archive = File(p.join(root.path, 'size.tar'));
      await Stream<TarEntry>.fromIterable([
        TarEntry.data(TarHeader(name: 'file', mode: 420), bytes),
      ]).transform(tarWriter).pipe(archive.openWrite());
      final expected = ArchiveInventory({
        'file': (size: 2, mode: 420, sha256: sha256.convert(bytes).toString()),
      });
      await withArchiveInput(
        archive,
        (input) => expectLater(
          verifyTarInput(input, expected, dialect: TarDialect.pubUpload),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'diagnostic',
              contains('Unexpected TAR member metadata'),
            ),
          ),
        ),
      );
    },
  );
  test(
    'pub upload dialect rejects unowned directories and native PAX metadata',
    () async {
      for (final longPath in [false, true]) {
        final name = longPath ? '${'x' * 110}/file' : 'file';
        final expected = ArchiveInventory({
          name: (size: 1, mode: 420, sha256: sha256.convert([7]).toString()),
        });
        final archive = File(p.join(root.path, 'dialect.tar'));
        await Stream<TarEntry>.fromIterable([
          if (!longPath)
            TarEntry.data(
              TarHeader(name: 'unowned', mode: 493, typeFlag: TypeFlag.dir),
              [],
            ),
          TarEntry.data(TarHeader(name: name, mode: 420), [7]),
        ]).transform(tarWriter).pipe(archive.openWrite());
        await withArchiveInput(
          archive,
          (input) => expectLater(
            verifyTarInput(input, expected, dialect: TarDialect.pubUpload),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'diagnostic',
                contains(longPath ? 'PAX' : 'Unexpected pub upload directory'),
              ),
            ),
          ),
        );
      }
    },
  );
}
