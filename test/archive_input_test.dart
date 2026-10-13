import 'dart:io';

import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import 'support/native_file_fixtures.dart';

const abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  late Directory root;
  late Directory snapshots;
  setUp(() {
    final temporary = Directory.systemTemp.createTempSync(
      'archive-input-test-',
    );
    root = Directory(temporary.resolveSymbolicLinksSync());
    snapshots = Directory('${root.path}/snapshots')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('snapshot owns exact bytes independently of the input file', () async {
    final source = File('${root.path}/archive')..writeAsStringSync('abc');
    await withArchiveInput(source, (input) async {
      expect(input.size, 3);
      expect(input.sha256, abcSha256);
      expect(input.file.path, isNot(source.path));
      source.writeAsStringSync('changed');
      expect(await input.file.readAsString(), 'abc');
    }, temporaryParent: snapshots);
    expect(snapshots.listSync(), isEmpty);
  });
  test(
    'file-backed input obeys a tighter caller bound without exposing data',
    () async {
      final source = File('${root.path}/large');
      final handle = source.openSync(mode: FileMode.write);
      handle.truncateSync(1024 * 1024);
      handle.closeSync();
      var inspected = false;
      await expectLater(
        withArchiveInput(
          source,
          (_) async {
            inspected = true;
          },
          maxBytes: 65536,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(inspected, isFalse);
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test('rejects direct and parent aliases before making a snapshot', () async {
    final source = File('${root.path}/archive')..writeAsStringSync('abc');
    final alias = Link('${root.path}/alias')..createSync(source.path);
    final parent = Link('${root.path}/parent')..createSync(root.path);
    for (final path in [alias.path, '${parent.path}/archive']) {
      await expectLater(
        withArchiveInput(File(path), (_) async {
          fail('Aliased input reached inspection');
        }, temporaryParent: snapshots),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    }
  });

  test(
    'pinned input identity rejects changed bytes before inspection',
    () async {
      final source = File('${root.path}/archive')..writeAsStringSync('abd');
      await expectLater(
        withArchiveInput(
          source,
          (_) async {
            fail('Unpinned bytes reached inspection');
          },
          expected: (size: 3, sha256: abcSha256),
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test(
    'inventory preserves Unicode names, modes and exact hash identities',
    () {
      final files = {
        'bin/café/archway': (size: 3, mode: 0x1ed, sha256: abcSha256),
        'guide.md': (size: 3, mode: 0x1a4, sha256: abcSha256),
      };
      final inventory = ArchiveInventory(files);
      files.clear();
      expect(inventory.files['bin/café/archway'], (
        size: 3,
        mode: 0x1ed,
        sha256: abcSha256,
      ));
      inventory.checkMembers([
        (name: 'guide.md', size: 3, mode: 0x1a4),
        (name: 'bin/café/archway', size: 3, mode: 0x1ed),
      ]);
      expect(() => inventory.files.clear(), throwsUnsupportedError);
    },
  );

  test(
    'preflight requires every member exactly once with matching metadata',
    () {
      final inventory = ArchiveInventory({
        'a': (size: 3, mode: 0x1a4, sha256: abcSha256),
        'b': (size: 3, mode: 0x1ed, sha256: abcSha256),
      });
      const a = (name: 'a', size: 3, mode: 0x1a4);
      const b = (name: 'b', size: 3, mode: 0x1ed);
      for (final members in <List<ArchiveMember>>[
        [a],
        [a, b, a],
        [a, b, (name: 'c', size: 3, mode: 0x1a4)],
        [a, (name: 'b', size: 2, mode: 0x1ed)],
        [a, (name: 'b', size: 3, mode: 0x1a4)],
      ]) {
        expect(
          () => inventory.checkMembers(members),
          throwsFormatException,
          reason: '$members',
        );
      }
    },
  );

  test('inventory rejects noncanonical paths and every ASCII control', () {
    for (final name in [
      '',
      '/a',
      'a/',
      'a//b',
      '.',
      'a/../b',
      'a/./b',
      r'a\b',
      'C:a',
      'a.',
      'a ',
      'CON.txt',
      'dir/Lpt1',
      for (var code = 0; code < 32; code++) 'a${String.fromCharCode(code)}b',
    ]) {
      expect(
        () =>
            ArchiveInventory({name: (size: 3, mode: 0x1a4, sha256: abcSha256)}),
        throwsFormatException,
        reason: 'Path code units ${name.codeUnits}',
      );
    }
  });

  test('inventory rejects aliases and file-parent collisions in any order', () {
    for (final names in [
      ['file', 'FILE'],
      ['file', 'file/child'],
      ['file/child', 'file'],
      ['File/child', 'file'],
      ['Dir/a', 'dir/b'],
      ['caf\u00e9/a', 'cafe\u0301/b'],
    ]) {
      expect(
        () => ArchiveInventory({
          for (final name in names)
            name: (size: 3, mode: 0x1a4, sha256: abcSha256),
        }),
        throwsFormatException,
        reason: '$names',
      );
    }
  });

  test(
    'inventory enforces file, total and count ceilings plus tighter limits',
    () {
      ArchiveFileIdentity entry(int size) =>
          (size: size, mode: 0x1a4, sha256: abcSha256);
      expect(
        () => ArchiveInventory({'a': entry(128 * 1024 * 1024 + 1)}),
        throwsFormatException,
      );
      expect(
        () => ArchiveInventory({
          for (var i = 0; i < 5; i++) 'file$i': entry(128 * 1024 * 1024),
        }),
        throwsFormatException,
      );
      expect(
        () => ArchiveInventory({
          for (var i = 0; i < 4097; i++) 'file$i': entry(0),
        }),
        throwsFormatException,
      );
      expect(
        () => ArchiveInventory({'a': entry(3)}, maxFileBytes: 2),
        throwsFormatException,
      );
      expect(
        () => ArchiveInventory({'a': entry(3)}, maxTotalBytes: 2),
        throwsFormatException,
      );
      expect(
        () => ArchiveInventory({'a': entry(3)}, maxEntries: 0),
        throwsFormatException,
      );
      final atBounds = ArchiveInventory({
        for (var i = 0; i < 4; i++) 'file$i': entry(128 * 1024 * 1024),
      });
      expect(atBounds.files.length, 4);
    },
  );

  test('inventory rejects invalid modes, sizes and SHA-256 identities', () {
    for (final entry in <ArchiveFileIdentity>[
      (size: -1, mode: 0x1a4, sha256: abcSha256),
      (size: 3, mode: 0x81a4, sha256: abcSha256),
      (size: 3, mode: 0x9ed, sha256: abcSha256),
      (size: 3, mode: 0x1a4, sha256: abcSha256.toUpperCase()),
      (size: 3, mode: 0x1a4, sha256: '${abcSha256}\n'),
      (size: 3, mode: 0x1a4, sha256: 'abc'),
    ]) {
      expect(() => ArchiveInventory({'a': entry}), throwsFormatException);
    }
    for (final mode in [0x1a4, 0x1ed, 0x1b6, 0x1ff]) {
      expect(
        ArchiveInventory({'a': (size: 3, mode: mode, sha256: abcSha256)})
            .files['a']!
            .mode,
        mode,
      );
    }
  });

  test('callers can tighten but cannot disable inventory bounds', () {
    expect(
      () => ArchiveInventory({}, maxFileBytes: 128 * 1024 * 1024 + 1),
      throwsArgumentError,
    );
    expect(
      () => ArchiveInventory({}, maxTotalBytes: 512 * 1024 * 1024 + 1),
      throwsArgumentError,
    );
    expect(() => ArchiveInventory({}, maxEntries: 4097), throwsArgumentError);
    expect(() => ArchiveInventory({}, maxEntries: -1), throwsArgumentError);
  });

  test(
    'rejects actual nonregular input without reading or creating snapshots',
    () async {
      final path = '${root.path}/resource';
      createNonregularResource(path);
      try {
        await expectLater(
          withArchiveInput(File(path), (_) async {
            fail('Nonregular input reached inspection');
          }, temporaryParent: snapshots),
          throwsFormatException,
        );
        expect(snapshots.listSync(), isEmpty);
      } finally {
        removeNonregularResource(path);
      }
    },
  );

  test(
    'callback rejection removes its private snapshot and preserves source',
    () async {
      final source = File('${root.path}/archive')..writeAsStringSync('abc');
      await expectLater(
        withArchiveInput(source, (_) async {
          throw const FormatException('Rejected archive');
        }, temporaryParent: snapshots),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
      expect(source.readAsStringSync(), 'abc');
    },
  );

  test('file-backed archive and JSON ceilings cannot be relaxed', () async {
    final source = File('${root.path}/oversized');
    for (final limit in [maxArchiveBytes, maxArchiveJsonBytes]) {
      final handle = source.openSync(mode: FileMode.write);
      handle.truncateSync(limit + 1);
      handle.closeSync();
      await expectLater(
        withArchiveInput(
          source,
          (_) async {
            fail('Oversize input reached inspection');
          },
          maxBytes: limit,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    }
    await expectLater(
      withArchiveInput(source, (_) async {}, maxBytes: maxArchiveBytes + 1),
      throwsArgumentError,
    );
    await expectLater(
      withArchiveInput(source, (_) async {}, maxBytes: -1),
      throwsArgumentError,
    );
  });
  test(
    'inventory refuses conservative Unicode case aliases in every component',
    () {
      for (final names in [
        ['Σ', 'ς'],
        ['Σ/a', 'ς/b'],
        ['ß/a', 'ẞ/b'],
      ]) {
        expect(
          () => ArchiveInventory({
            for (final name in names)
              name: (size: 3, mode: 0x1a4, sha256: abcSha256),
          }),
          throwsFormatException,
          reason: '$names',
        );
      }
    },
  );

  test('portable alias policy does not apply multi-character case folding', () {
    final inventory = ArchiveInventory({
      'Straße': (size: 3, mode: 0x1a4, sha256: abcSha256),
      'STRASSE': (size: 3, mode: 0x1a4, sha256: abcSha256),
    });
    expect(inventory.files.length, 2);
  });

  test(
    'stream growth past the byte bound rejects and removes the snapshot',
    () async {
      final file = File('${root.path}/growing')..writeAsStringSync('abc');
      final source = _FileGrowingAfterStat(file);
      await expectLater(
        withArchiveInput(
          source,
          (_) async {
            fail('Oversize stream reached inspection');
          },
          maxBytes: 3,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      expect(source.readStarted, isTrue);
      expect(file.readAsStringSync(), 'abcd');
      expect(snapshots.listSync(), isEmpty);
    },
  );
}

// Narrow filesystem fixture: real input grows after its initial size check.
// Unused File operations deliberately fail rather than silently forwarding.
final class _FileGrowingAfterStat implements File {
  _FileGrowingAfterStat(this.file);
  final File file;
  var readStarted = false;
  @override
  String get path => file.path;
  @override
  File get absolute => file.absolute;
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Future<FileStat> stat() async {
    final original = await file.stat();
    await file.writeAsString('abcd');
    return original;
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    readStarted = true;
    return file.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
