import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/archive_extraction.dart';
import '../tool/release/tar_input.dart';
import '../tool/release/zip_input.dart';
import 'zip_input_test.dart' show zip;
import 'tar_extraction_test.dart' show abc, member;

void main() {
  late Directory root, cache;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('archive-publication-')
          .resolveSymbolicLinksSync(),
    );
    cache = Directory(p.join(root.path, 'cache'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'TAR transfers verified bytes after the callback without deleting them',
    () async {
      final source = File(p.join(root.path, 'source.tar'))
        ..writeAsBytesSync(member('bin/café', mode: 0x1ed));
      final destination = Directory(p.join(cache.path, 'native'));
      late Directory stage;
      final result = await withArchiveInput(
        source,
        (input) => withTarExtraction(
          input,
          ArchiveInventory({'bin/café': (size: 3, mode: 0x1ed, sha256: abc)}),
          (directory) async {
            stage = directory;
            expect(directory.path, directory.resolveSymbolicLinksSync());
            expect(directory.parent.path, cache.path);
            expect(destination.existsSync(), isFalse);
            expect(
              File(p.join(directory.path, 'bin', 'café')).readAsBytesSync(),
              [97, 98, 99],
            );
            return 'inspected';
          },
          publishTo: destination,
        ),
      );
      expect(result, 'inspected');
      expect(stage.existsSync(), isFalse);
      final payload = File(p.join(destination.path, 'bin', 'café'));
      expect(payload.readAsBytesSync(), [97, 98, 99]);
      if (!Platform.isWindows) expect(payload.statSync().mode & 0xfff, 0x1ed);
      expect(cache.listSync().map((e) => e.path), [destination.path]);
    },
  );
  test(
    'ZIP publishes empty and nested files with exact bytes and modes',
    () async {
      for (final mode in [0x1a4, 0x1ed, 0x1b6, 0x1ff]) {
        final source = File(p.join(root.path, 'source.zip'))
          ..writeAsBytesSync(
            zip([
              ('bin/café', [97, 98, 99]),
              ('empty', <int>[]),
            ], mode: 0x8000 | mode),
          );
        final destination = Directory(p.join(cache.path, '$mode'));
        late Directory stage;
        await withArchiveInput(
          source,
          (input) => withZipExtraction(
            input,
            ArchiveInventory({
              'bin/café': (size: 3, mode: mode, sha256: abc),
              'empty': (
                size: 0,
                mode: mode,
                sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
              ),
            }),
            (directory) async {
              stage = directory;
              expect(directory.parent.path, cache.path);
              expect(directory.path, directory.resolveSymbolicLinksSync());
              expect(destination.existsSync(), isFalse);
              expect(
                File(p.join(directory.path, 'empty')).readAsBytesSync(),
                isEmpty,
              );
            },
            publishTo: destination,
          ),
        );
        expect(stage.existsSync(), isFalse);
        for (final (name, bytes) in [
          ('bin/café', [97, 98, 99]),
          ('empty', <int>[]),
        ]) {
          final file = File(p.joinAll([destination.path, ...name.split('/')]));
          expect(file.readAsBytesSync(), bytes);
          if (!Platform.isWindows) expect(file.statSync().mode & 0xfff, mode);
        }
        if (!Platform.isWindows)
          expect(destination.statSync().mode & 0xfff, 0x1c0);
      }
      expect(cache.listSync(), hasLength(4));
    },
  );

  test(
    'existing destination is preserved before extraction callback exposure',
    () async {
      final source = File(p.join(root.path, 'source.tar'))
        ..writeAsBytesSync(member('payload'));
      final destination = Directory(p.join(cache.path, 'native'))..createSync();
      final winner = File(p.join(destination.path, 'winner'))
        ..writeAsStringSync('keep');
      var called = false;
      await expectLater(
        withArchiveInput(
          source,
          (input) => withTarExtraction(
            input,
            ArchiveInventory({'payload': (size: 3, mode: 0x1a4, sha256: abc)}),
            (_) async {
              called = true;
            },
            publishTo: destination,
          ),
        ),
        throwsA(isA<ArchiveDestinationExists>()),
      );
      expect(called, isFalse);
      expect(winner.readAsStringSync(), 'keep');
      expect(destination.listSync().map((e) => e.path), [winner.path]);
      expect(cache.listSync().map((e) => e.path), [destination.path]);
    },
  );

  test(
    'noncanonical publication routes are refused before callback exposure',
    () async {
      final source = File(p.join(root.path, 'source.tar'))
        ..writeAsBytesSync(member('payload'));
      final alias = Link(p.join(root.path, 'alias'))..createSync(cache.path);
      for (final destination in [
        Directory(p.join(alias.path, 'native')),
        Directory('${cache.path}${p.separator}.${p.separator}native'),
        Directory(p.join(cache.path, 'native\x00suffix')),
      ]) {
        var called = false;
        await expectLater(
          withArchiveInput(
            source,
            (input) => withTarExtraction(
              input,
              ArchiveInventory({
                'payload': (size: 3, mode: 0x1a4, sha256: abc),
              }),
              (_) async {
                called = true;
              },
              publishTo: destination,
            ),
          ),
          throwsFormatException,
        );
        expect(called, isFalse);
        expect(cache.listSync(), isEmpty);
      }
    },
  );

  test(
    'malformed or checksum-invalid archives never expose or publish a stage',
    () async {
      for (final format in ['tar', 'zip']) {
        for (final failure in ['metadata', 'checksum']) {
          final second = failure == 'metadata' ? 'other' : 'second';
          final source = File(p.join(root.path, 'source.$format'))
            ..writeAsBytesSync(
              format == 'tar'
                  ? [...member('first').take(1024), ...member(second)]
                  : zip([
                      ('first', [97, 98, 99]),
                      (second, [97, 98, 99]),
                    ]),
            );
          final inventory = ArchiveInventory({
            'first': (size: 3, mode: 0x1a4, sha256: abc),
            'second': (
              size: 3,
              mode: 0x1a4,
              sha256: failure == 'checksum' ? '0' * 64 : abc,
            ),
          });
          final destination = Directory(p.join(cache.path, 'native'));
          var called = false;
          Future<void> inspect(Directory _) async {
            called = true;
          }

          await expectLater(
            withArchiveInput(
              source,
              (input) => format == 'tar'
                  ? withTarExtraction(
                      input,
                      inventory,
                      inspect,
                      publishTo: destination,
                    )
                  : withZipExtraction(
                      input,
                      inventory,
                      inspect,
                      publishTo: destination,
                    ),
            ),
            throwsFormatException,
          );
          expect(called, isFalse);
          expect(cache.listSync(), isEmpty);
        }
      }
    },
  );

  test(
    'a later winner survives publication collision and loser cleanup',
    () async {
      final source = File(p.join(root.path, 'source.zip'))
        ..writeAsBytesSync(
          zip([
            ('payload', [97, 98, 99]),
          ]),
        );
      final destination = Directory(p.join(cache.path, 'native'));
      late Directory stage;
      final winner = File(p.join(destination.path, 'winner'));
      await expectLater(
        withArchiveInput(
          source,
          (input) => withZipExtraction(
            input,
            ArchiveInventory({'payload': (size: 3, mode: 0x1a4, sha256: abc)}),
            (directory) async {
              stage = directory;
              expect(File(p.join(stage.path, 'payload')).readAsBytesSync(), [
                97,
                98,
                99,
              ]);
              destination.createSync();
              winner.writeAsStringSync('keep');
            },
            publishTo: destination,
          ),
        ),
        throwsA(isA<ArchiveDestinationExists>()),
      );
      expect(stage.existsSync(), isFalse);
      expect(winner.readAsStringSync(), 'keep');
      expect(destination.listSync().map((e) => e.path), [winner.path]);
      expect(cache.listSync().map((e) => e.path), [destination.path]);
    },
  );

  test(
    'callback filesystem failure stays distinct from an existing winner',
    () async {
      final source = File(p.join(root.path, 'source.zip'))
        ..writeAsBytesSync(
          zip([
            ('payload', [97, 98, 99]),
          ]),
        );
      final destination = Directory(p.join(cache.path, 'native'));
      final winner = File(p.join(destination.path, 'winner'));
      final error = FileSystemException(
        'callback failed',
        destination.path,
        const OSError('fixture', 17),
      );
      late Directory stage;
      await expectLater(
        withArchiveInput(
          source,
          (input) => withZipExtraction(
            input,
            ArchiveInventory({'payload': (size: 3, mode: 0x1a4, sha256: abc)}),
            (directory) async {
              stage = directory;
              expect(File(p.join(stage.path, 'payload')).readAsBytesSync(), [
                97,
                98,
                99,
              ]);
              destination.createSync();
              winner.writeAsStringSync('keep');
              throw error;
            },
            publishTo: destination,
          ),
        ),
        throwsA(same(error)),
      );
      expect(stage.existsSync(), isFalse);
      expect(winner.readAsStringSync(), 'keep');
      expect(cache.listSync().map((e) => e.path), [destination.path]);
    },
  );
}
