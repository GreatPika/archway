import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/gzip_input.dart';

void main() {
  late Directory root;
  late Directory snapshots;
  setUp(() {
    final temporary = Directory.systemTemp.createTempSync('gzip-input-test-');
    root = Directory(temporary.resolveSymbolicLinksSync());
    snapshots = Directory(p.join(root.path, 'snapshots'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> rejected(List<int> bytes) async {
    final source = File(p.join(root.path, 'invalid.gz'))
      ..writeAsBytesSync(bytes);
    await expectLater(
      withGzipInput(source, (_) async {
        fail('Invalid gzip reached inspection');
      }, temporaryParent: snapshots),
      throwsFormatException,
    );
    expect(snapshots.listSync(), isEmpty);
  }

  test(
    'gzip input yields decoded bytes in an owned file and cleans it up',
    () async {
      final source = File(p.join(root.path, 'input.gz'))
        ..writeAsBytesSync(gzip.encode([97, 98, 99]));
      late File expanded;
      await withGzipInput(source, (file) async {
        expanded = file;
        expect(await file.readAsBytes(), [97, 98, 99]);
        expect(file.path, isNot(source.path));
        expect(file.resolveSymbolicLinksSync(), file.path);
        await withArchiveInput(file, (input) async {
          expect(input.file.resolveSymbolicLinksSync(), input.file.path);
          expect(await input.file.readAsBytes(), [97, 98, 99]);
        }, temporaryParent: snapshots);
      }, temporaryParent: snapshots);
      expect(expanded.existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
      expect(snapshots.listSync(), isEmpty);
    },
  );
  test(
    'expanded data is bounded before inspection and partial output is removed',
    () async {
      final source = File(p.join(root.path, 'bomb.gz'))
        ..writeAsBytesSync(gzip.encode(Uint8List(2 * 1024 * 1024)));
      await expectLater(
        withGzipInput(
          source,
          (_) async {
            fail('Oversize output reached inspection');
          },
          maxExpandedBytes: 1024,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test(
    'caller may tighten but cannot disable expanded snapshot bounds',
    () async {
      final source = File(p.join(root.path, 'empty.gz'))
        ..writeAsBytesSync(gzip.encode([]));
      for (final limit in [-1, 512 * 1024 * 1024 + 1]) {
        await expectLater(
          withGzipInput(
            source,
            (_) async {},
            maxExpandedBytes: limit,
            temporaryParent: snapshots,
          ),
          throwsArgumentError,
        );
        expect(snapshots.listSync(), isEmpty);
      }
      await withGzipInput(
        source,
        (file) async {
          expect(await file.length(), 0);
        },
        maxExpandedBytes: 0,
        temporaryParent: snapshots,
      );
    },
  );

  test('requires gzip framing rather than the decoder zlib fallback', () async {
    final zlibBytes = zlib.encode([97, 98, 99]);
    // The library fallback also accepts zlib with a little-endian checksum.
    await rejected([
      ...zlibBytes.take(zlibBytes.length - 4),
      ...zlibBytes.skip(zlibBytes.length - 4).toList().reversed,
    ]);
    await rejected(zlibBytes);
    await rejected([]);
    final encoded = gzip.encode([97, 98, 99]);
    await rejected([...encoded]..[0] = 0);
    await rejected([...encoded]..[2] = 0);
  });

  test(
    'verifies data CRC and declared length before exposing decoded data',
    () async {
      final encoded = gzip.encode([97, 98, 99]);
      await rejected([...encoded]..[encoded.length - 8] ^= 1);
      await rejected([...encoded]..[encoded.length - 4] ^= 1);
    },
  );

  test(
    'rejects every shortened trailer and truncation inside the fixed header',
    () async {
      final encoded = gzip.encode([97, 98, 99]);
      for (var count = 1; count <= 9; count++) {
        await rejected(encoded.sublist(0, encoded.length - count));
        await rejected(encoded.sublist(0, count));
      }
    },
  );

  test(
    'valid concatenated members and empty members preserve all bytes',
    () async {
      final first = gzip.encode([97, 98, 99]);
      final second = gzip.encode([100, 101, 102]);
      final empty = gzip.encode([]);
      final source = File(p.join(root.path, 'concatenated.gz'))
        ..writeAsBytesSync([...empty, ...first, ...second, ...empty]);
      await withGzipInput(
        source,
        (file) async {
          expect(await file.readAsBytes(), [97, 98, 99, 100, 101, 102]);
        },
        maxExpandedBytes: 6,
        temporaryParent: snapshots,
      );
      await expectLater(
        withGzipInput(
          source,
          (_) async {
            fail('Combined expansion exceeded its bound');
          },
          maxExpandedBytes: 5,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test(
    'truncated or corrupted later members cannot hide behind a valid first',
    () async {
      final first = gzip.encode([97, 98, 99]);
      final empty = gzip.encode([]);
      await rejected([...first, ...empty.sublist(0, empty.length - 4)]);
      final second = gzip.encode([100, 101, 102]);
      await rejected([
        ...first,
        ...([...second]..[second.length - 8] ^= 1),
      ]);
      await rejected([...first, ...second.sublist(0, second.length - 1)]);
    },
  );

  test(
    'refuses trailing padding and nonmember data after a complete member',
    () async {
      final first = gzip.encode([97, 98, 99]);
      await rejected([...first, 0]);
      await rejected([...first, 1, 2, 3]);
      await rejected([...first, 31, 139, 8]);
    },
  );
  test('truncated optional header fields fail before inspection', () async {
    final encoded = gzip.encode([97, 98, 99]);
    for (final (flag, tail) in [
      (4, [255, 255]),
      (8, [65]),
      (16, [65]),
      (2, [0]),
    ]) {
      await rejected([
        ...([...encoded.take(10)]..[3] = flag),
        ...tail,
      ]);
    }
    await rejected([...encoded]..[10] = 7); // Reserved deflate block type.
  });

  test(
    'file-backed buffer boundaries and an original Unicode filename roundtrip',
    () async {
      final contents = Uint8List.fromList(
        List.generate(1024 * 1024 + 17, (i) => i % 251),
      );
      final encoded = gzip.encode(contents);
      final source = File(p.join(root.path, 'long.gz'))
        ..writeAsBytesSync([
          ...([...encoded.take(10)]..[3] = 8),
          ...utf8.encode('archive café 😀.tar'),
          0,
          ...encoded.skip(10),
        ]);
      await withGzipInput(
        source,
        (file) async {
          expect(await file.readAsBytes(), contents);
        },
        maxExpandedBytes: contents.length,
        temporaryParent: snapshots,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test(
    'verified input limits and pinned identity are enforced before decoding',
    () async {
      final encoded = gzip.encode([97, 98, 99]);
      final source = File(p.join(root.path, 'pinned.gz'))
        ..writeAsBytesSync(encoded);
      await expectLater(
        withGzipInput(
          source,
          (_) async {
            fail('Oversize compressed input reached inspection');
          },
          maxBytes: encoded.length - 1,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      await expectLater(
        withGzipInput(
          source,
          (_) async {
            fail('Unpinned input reached inspection');
          },
          expected: (size: encoded.length, sha256: '0' * 64),
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test('callback failure closes output and removes all owned files', () async {
    final source = File(p.join(root.path, 'rejected.gz'))
      ..writeAsBytesSync(gzip.encode([97]));
    await expectLater(
      withGzipInput(source, (_) async {
        throw StateError('Consumer rejected decoded input');
      }, temporaryParent: snapshots),
      throwsStateError,
    );
    expect(snapshots.listSync(), isEmpty);
    expect(source.existsSync(), isTrue);
  });
}
