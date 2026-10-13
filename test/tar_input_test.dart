import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/tar_input.dart';

const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
List<int> ordinary({String name = 'payload', int mode = 0x1a4}) => tarConverter
    .convert(TarEntry.data(TarHeader(name: name, mode: mode), [97, 98, 99]));

List<int> changedHeader(List<int> bytes, void Function(List<int>) change) {
  final header = bytes.take(512).toList();
  change(header);
  header.fillRange(148, 156, 32);
  final sum = header.fold<int>(0, (sum, byte) => sum + byte);
  header.setRange(
    148,
    156,
    ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '),
  );
  return [...header, ...bytes.skip(512)];
}

List<int> paxRecord(String key, String value) {
  final suffix = utf8.encode(' $key=$value\n');
  var length = suffix.length + 1;
  while ('$length'.length + suffix.length != length) {
    length = '$length'.length + suffix.length;
  }
  return [...ascii.encode('$length'), ...suffix];
}

List<int> withPax(List<int> body, {List<int>? following, int type = 120}) {
  final header = changedHeader(ordinary(), (h) {
    h[156] = type;
    h.setRange(
      124,
      136,
      ascii.encode('${body.length.toRadixString(8).padLeft(11, '0')}\x00'),
    );
  }).take(512);
  return [
    ...header,
    ...body,
    ...List.filled((512 - body.length % 512) % 512, 0),
    ...(following ?? ordinary()),
  ];
}

void main() {
  late Directory root;
  late Directory snapshots;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('tar-input-test-')
          .resolveSymbolicLinksSync(),
    );
    snapshots = Directory(p.join(root.path, 'snapshots'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<void> verify(
    List<int> bytes, {
    String name = 'payload',
    int mode = 0x1a4,
    Map<String, ArchiveFileIdentity>? files,
  }) async {
    final source = File(p.join(root.path, 'input.tar'))
      ..writeAsBytesSync(bytes);
    await withArchiveInput(
      source,
      (input) => verifyTarInput(
        input,
        ArchiveInventory(files ?? {name: (size: 3, mode: mode, sha256: abc)}),
      ),
      temporaryParent: snapshots,
    );
    expect(snapshots.listSync(), isEmpty);
  }

  test('ordinary TAR contents match the complete expected inventory', () async {
    await verify(ordinary());
  });
  test('matching header metadata cannot hide changed file bytes', () async {
    await expectLater(
      verify([...ordinary()]..[512] = 100),
      throwsFormatException,
    );
    expect(snapshots.listSync(), isEmpty);
  });

  test(
    'requires zero body padding and two complete zero terminator blocks',
    () async {
      final bytes = ordinary();
      for (final bad in [
        [...bytes]..[515] = 1,
        bytes.sublist(0, 1024),
        bytes.sublist(0, 1536),
        [...bytes, ...List.filled(511, 0), 1],
        [...bytes, 0],
      ]) {
        await expectLater(verify(bad), throwsFormatException);
        expect(snapshots.listSync(), isEmpty);
      }
    },
  );

  test(
    'PAX Unicode long paths preserve effective names and producer modes',
    () async {
      final name = 'bin/${'café' * 40}';
      for (final mode in [0x1a4, 0x1ed, 0x1b6, 0x1ff]) {
        await verify(
          ordinary(name: name, mode: mode),
          name: name,
          mode: mode,
        );
      }
    },
  );

  test(
    'allows only one local PAX header with approved effective metadata',
    () async {
      final body = [
        for (final (key, value) in [
          ('path', 'payload'),
          ('mtime', '1720000000.125'),
          ('atime', '1720000000'),
          ('ctime', '1720000000'),
          ('uid', '42'),
          ('gid', '43'),
          ('uname', 'owner'),
          ('gname', 'group'),
        ])
          ...paxRecord(key, value),
      ];
      await verify(withPax(body));
      await expectLater(
        verify(withPax(body, following: withPax(body))),
        throwsFormatException,
      );
      await expectLater(
        verify(withPax(body, following: List.filled(1024, 0))),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects global PAX, sparse and unknown metadata before file processing',
    () async {
      for (final key in [
        'GNU.sparse.size',
        'GNU.sparse.map',
        'GNU.sparse.major',
        'GNU.sparse.realsize',
        'SCHILY.filetype',
        'size',
        'linkpath',
        'unknown',
      ]) {
        await expectLater(
          verify(withPax(paxRecord(key, '3'))),
          throwsFormatException,
        );
      }
      await expectLater(
        verify(withPax(paxRecord('path', 'payload'), type: 103)),
        throwsFormatException,
      );
    },
  );

  test(
    'strict PAX framing rejects malformed, duplicated and empty values',
    () async {
      for (final body in [
        utf8.encode('99 path=safe\n'),
        utf8.encode('0 path=safe\n'),
        utf8.encode('13 path=safeX'),
        [...paxRecord('path', 'payload'), ...paxRecord('path', 'payload')],
        paxRecord('path', ''),
        paxRecord('path', 'a\x00b'),
        [55, 32, 255, 61, 120, 121, 10],
      ]) {
        await expectLater(verify(withPax(body)), throwsFormatException);
      }
    },
  );

  test(
    'ordinary type, exact names and bounded fields survive raw header parsing',
    () async {
      for (final type in '1234567SgLKX'.codeUnits) {
        await expectLater(
          verify(changedHeader(ordinary(), (h) => h[156] = type)),
          throwsFormatException,
        );
      }
      await verify(changedHeader(ordinary(), (h) => h[156] = 0));
      for (final change in <void Function(List<int>)>[
        (h) => h[157] = 32,
        (h) => h.setRange(124, 136, ascii.encode('01000000001\x00')),
        (h) => h.setRange(124, 136, List.filled(12, 255)),
        (h) => h.setRange(124, 136, ascii.encode('garbage     ')),
        (h) => h.setRange(124, 136, ascii.encode('00000000003\n')),
        (h) => h[0] = 255,
        (h) => h.setRange(0, 9, utf8.encode('payload \x00')),
        (h) => h.setRange(100, 108, ascii.encode('0004755\x00')),
      ]) {
        await expectLater(
          verify(changedHeader(ordinary(), change)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'all checksums, body bounds and complete inventory membership are required',
    () async {
      await expectLater(
        verify([...ordinary()]..[0] ^= 1),
        throwsFormatException,
      );
      await expectLater(
        verify([...withPax(paxRecord('path', 'payload'))]..[0] ^= 1),
        throwsFormatException,
      );
      await expectLater(
        verify(ordinary().sublist(0, 513)),
        throwsFormatException,
      );
      final pair = {
        'payload': (size: 3, mode: 0x1a4, sha256: abc),
        'other': (size: 3, mode: 0x1a4, sha256: abc),
      };
      await verify([
        ...ordinary().take(1024),
        ...ordinary(name: 'other'),
      ], files: pair);
      await expectLater(verify(ordinary(), files: pair), throwsFormatException);
      await expectLater(
        verify([...ordinary().take(1024), ...ordinary()], files: pair),
        throwsFormatException,
      );
      for (final name in [
        '../escape',
        '/absolute',
        'PAYLOAD',
        'payload/child',
        'a\tb',
      ]) {
        await expectLater(verify(ordinary(name: name)), throwsFormatException);
        await expectLater(
          verify(withPax(paxRecord('path', name))),
          throwsFormatException,
        );
      }
    },
  );
  test('sparse-looking payload text remains ordinary data', () async {
    final bytes = tarConverter.convert(
      TarEntry.data(
        TarHeader(name: 'payload', mode: 0x1a4),
        utf8.encode('GNU.sparse.map=0,100\n'),
      ),
    );
    await verify(
      bytes,
      files: {
        'payload': (
          size: 21,
          mode: 0x1a4,
          sha256: '4a3c3a72990cb5bff894f9ea14a2712deb983fcec4949b1be0a638905a3b969a',
        ),
      },
    );
  });

  test('metadata declared bound is checked before reading its body', () async {
    await expectLater(
      verify(
        changedHeader(ordinary(), (h) {
          h[156] = 120;
          h.setRange(124, 136, ascii.encode('00004000001\x00'));
        }),
      ),
      throwsFormatException,
    );
    await verify([...ordinary(), ...List.filled(512, 0)]);
  });
}
