import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/zip_input.dart';

// Independent ZIP fixture writer: raw little-endian structures and SDK deflate,
// not the ZIP decoder under test. Matches release_bundles.py's seekable writer.
Uint8List zip(
  List<(String, List<int>)> files, {
  int mode = 0x81a4,
  List<int> Function(List<int>)? encode,
}) {
  final body = BytesBuilder(), directory = BytesBuilder();
  void integer(BytesBuilder out, int value, int width) {
    for (var i = 0; i < width; i++) out.addByte((value >> (8 * i)) & 255);
  }

  for (final (name, bytes) in files) {
    final encoded = utf8.encode(name),
        compressed = (encode ?? ZLibCodec(raw: true).encode)(bytes);
    final flags = encoded.any((b) => b > 127) ? 0x800 : 0;
    final crc = archive.getCrc32(bytes), offset = body.length;
    integer(body, 0x04034b50, 4);
    for (final n in [20, flags, 8, 0, 0]) integer(body, n, 2);
    for (final n in [crc, compressed.length, bytes.length]) integer(body, n, 4);
    integer(body, encoded.length, 2);
    integer(body, 0, 2);
    body.add(encoded);
    body.add(compressed);
    integer(directory, 0x02014b50, 4);
    for (final n in [0x314, 20, flags, 8, 0, 0]) integer(directory, n, 2);
    for (final n in [crc, compressed.length, bytes.length])
      integer(directory, n, 4);
    for (final n in [encoded.length, 0, 0, 0, 0]) integer(directory, n, 2);
    integer(directory, mode << 16, 4);
    integer(directory, offset, 4);
    directory.add(encoded);
  }
  final start = body.length, length = directory.length;
  body.add(directory.takeBytes());
  integer(body, 0x06054b50, 4);
  for (final n in [0, 0, files.length, files.length]) integer(body, n, 2);
  integer(body, length, 4);
  integer(body, start, 4);
  integer(body, 0, 2);
  return body.takeBytes();
}

int central(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint32(bytes.length - 6, Endian.little);
void set16(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint16(offset, value, Endian.little);
void set32(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
ArchiveInventory inventory(List<(String, List<int>)> files) =>
    ArchiveInventory({
      for (final (name, bytes) in files)
        name: (
          size: bytes.length,
          mode: 0x1a4,
          sha256: crypto.sha256.convert(bytes).toString(),
        ),
    });

String fixtureSourcePath(String directory, p.Context paths) =>
    paths.join(directory, 'source.zip');

void main() {
  late Directory root;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('zip-input-test-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<T> inspect<T>(
    List<int> bytes,
    Future<T> Function(ArchiveInput) run,
  ) async {
    final file = File(fixtureSourcePath(root.path, p.context))
      ..writeAsBytesSync(bytes);
    // Negative ZIP controls must reach ZIP validation, not fail at the input
    // path guard because this fixture constructed a noncanonical spelling.
    expect(file.path, file.resolveSymbolicLinksSync());
    return withArchiveInput(file, run, temporaryParent: root);
  }

  test('fixture source uses native separators on Windows and POSIX', () {
    expect(
      fixtureSourcePath(
        r'C:\temp\zip-input-test',
        p.Context(style: p.Style.windows),
      ),
      r'C:\temp\zip-input-test\source.zip',
    );
    expect(
      fixtureSourcePath('/tmp/zip-input-test', p.Context(style: p.Style.posix)),
      '/tmp/zip-input-test/source.zip',
    );
  });

  test(
    'reads root manifest and verifies every payload without extraction',
    () async {
      final files = [
        ('manifest.json', utf8.encode('{"formatVersion":1}')),
        ('bin/é.exe', [1, 2, 3]),
      ];
      final bytes = zip(files);
      await inspect(bytes, (input) async {
        expect(await readZipManifest(input), files.first.$2);
        await verifyZipInput(
          input,
          ArchiveInventory({
            for (final (name, data) in files)
              name: (
                size: data.length,
                mode: 0x1a4,
                sha256: crypto.sha256.convert(data).toString(),
              ),
          }),
        );
      });
      expect(root.listSync().map((e) => e.uri.pathSegments.last), [
        'source.zip',
      ]);
    },
  );

  final manifest = [('manifest.json', utf8.encode('{}'))];
  test(
    'accepts Python zipfile.write producer fixture and creator OS 0 modes',
    () async {
      // Python 3 zipfile.ZipFile(path, 'x', compression=ZIP_DEFLATED).write(file, 'manifest.json'), chmod 0644.
      final bytes = base64.decode(
        'UEsDBBQAAAAIAJWsTV1Dv6ajBAAAAAIAAAANAAAAbWFuaWZlc3QuanNvbquuBQBQSwECFAMUAAAACACVrE1dQ7+mowQAAAACAAAADQAAAAAAAAAAAAAApIEAAAAAbWFuaWZlc3QuanNvblBLBQYAAAAAAQABADsAAAAvAAAAAAA=',
      );
      await inspect(
        bytes,
        (input) => verifyZipInput(input, inventory(manifest)),
      );
      set16(bytes, central(bytes) + 4, 20);
      await inspect(
        bytes,
        (input) => verifyZipInput(input, inventory(manifest)),
      );
    },
  );
  test(
    'accepts empty files and each existing import permission mode',
    () async {
      for (final mode in [0x1a4, 0x1ed, 0x1b6, 0x1ff]) {
        final bytes = zip([('empty', <int>[])], mode: 0x8000 | mode);
        await inspect(
          bytes,
          (input) => verifyZipInput(
            input,
            ArchiveInventory({
              'empty': (
                size: 0,
                mode: mode,
                sha256: crypto.sha256.convert([]).toString(),
              ),
            }),
          ),
        );
      }
    },
  );
  test('rejects malformed UTF8 and high bytes without UTF8 flag', () async {
    for (final flags in [0, 0x800]) {
      final bytes = zip(manifest), c = central(zip(manifest));
      set16(bytes, 6, flags);
      set16(bytes, c + 8, flags);
      bytes[30] = 255;
      bytes[c + 46] = 255;
      await expectLater(inspect(bytes, readZipManifest), throwsFormatException);
    }
  });
  final mutations = <String, void Function(Uint8List, int)>{
    'end signature': (b, c) => b[b.length - 22] = 0,
    'multi disk': (b, c) => set16(b, b.length - 18, 1),
    'disk counts': (b, c) => set16(b, b.length - 14, 0),
    'count lies': (b, c) {
      set16(b, b.length - 14, 0);
      set16(b, b.length - 12, 0);
    },
    'count bound': (b, c) {
      set16(b, b.length - 14, 4097);
      set16(b, b.length - 12, 4097);
    },
    'archive comment': (b, c) => set16(b, b.length - 2, 1),
    'central size': (b, c) => set32(b, b.length - 10, 1),
    'central signature': (b, c) => b[c] = 0,
    'creator OS': (b, c) => set16(b, c + 4, 0x614),
    'encrypted': (b, c) {
      set16(b, 6, 1);
      set16(b, c + 8, 1);
    },
    'descriptor': (b, c) {
      set16(b, 6, 8);
      set16(b, c + 8, 8);
    },
    'unknown method': (b, c) {
      set16(b, 8, 7);
      set16(b, c + 10, 7);
    },
    'local signature': (b, c) => b[0] = 0,
    'local size': (b, c) => set32(b, 22, 1),
    'local CRC': (b, c) => set32(b, 14, 0),
    'local flags': (b, c) => set16(b, 6, 0x800),
    'local name': (b, c) => b[30] = 120,
    'local extra': (b, c) => set16(b, 28, 1),
    'central extra': (b, c) => set16(b, c + 30, 1),
    'central comment': (b, c) => set16(b, c + 32, 1),
    'member disk': (b, c) => set16(b, c + 34, 1),
    'DOS directory': (b, c) => set32(b, c + 38, 0x81a40010),
    'symlink': (b, c) => set32(b, c + 38, 0xa1a40000),
    'directory': (b, c) => set32(b, c + 38, 0x41ed0000),
    'setuid': (b, c) => set32(b, c + 38, 0x89a40000),
    'unknown permission': (b, c) => set32(b, c + 38, 0x81800000),
    'local offset': (b, c) => set32(b, c + 42, 1),
    'compressed overlap': (b, c) {
      set32(b, 18, 1000);
      set32(b, c + 20, 1000);
    },
    'file bound': (b, c) {
      set32(b, 22, maxArchiveFileBytes + 1);
      set32(b, c + 24, maxArchiveFileBytes + 1);
    },
    'manifest bound': (b, c) {
      set32(b, 22, maxArchiveJsonBytes + 1);
      set32(b, c + 24, maxArchiveJsonBytes + 1);
    },
    'bad CRC': (b, c) {
      set32(b, 14, 0);
      set32(b, c + 16, 0);
    },
    'actual output over declared': (b, c) {
      set32(b, 22, 1);
      set32(b, c + 24, 1);
    },
    'actual output under declared': (b, c) {
      set32(b, 22, 3);
      set32(b, c + 24, 3);
    },
    'invalid deflate': (b, c) => b[43] = 7,
  };
  for (final mutation in mutations.entries) {
    test('refuses ${mutation.key} before returning a manifest', () async {
      final bytes = zip(manifest);
      mutation.value(bytes, central(bytes));
      await expectLater(
        inspect(bytes, readZipManifest),
        throwsA(isA<Exception>()),
      );
      expect(
        root.listSync().length,
        1,
        reason: 'owned snapshot cleaned after failure',
      );
    });
  }
  for (final name in [
    '',
    '/root',
    '../escape',
    'a/../b',
    'a//b',
    'a\\b',
    'C:foo',
    'NUL.txt',
    'trailing.',
    'trailing ',
    'folder/',
    'a\x00b',
  ]) {
    test('rejects unsafe name ${jsonEncode(name)}', () async {
      await expectLater(
        inspect(
          zip([
            ...manifest,
            (name, [1]),
          ]),
          readZipManifest,
        ),
        throwsFormatException,
      );
    });
  }
  for (final names in [
    ['same', 'same'],
    ['Case/a', 'case/b'],
    ['é', 'e\u0301'],
    ['file', 'file/child'],
  ]) {
    test(
      'rejects duplicate or alias $names before decoder can collapse it',
      () async {
        await expectLater(
          inspect(
            zip([
              ...manifest,
              for (final n in names) (n, [1]),
            ]),
            readZipManifest,
          ),
          throwsFormatException,
        );
      },
    );
  }
  test('rejects missing root manifest and external trailing bytes', () async {
    await expectLater(
      inspect(
        zip([
          ('nested/manifest.json', [1]),
        ]),
        readZipManifest,
      ),
      throwsFormatException,
    );
    await expectLater(
      inspect([...zip(manifest), 0], readZipManifest),
      throwsFormatException,
    );
    await expectLater(
      inspect(zip(manifest).sublist(0, 30), readZipManifest),
      throwsFormatException,
    );
  });
  test(
    'checks full inventory including members not decoded during discovery',
    () async {
      final files = [
        ...manifest,
        ('payload', [97, 98, 99]),
      ];
      final bytes = zip(files);
      await inspect(bytes, (input) async {
        expect(await readZipManifest(input), manifest.first.$2);
        await expectLater(
          verifyZipInput(input, inventory(manifest)),
          throwsFormatException,
        );
        await expectLater(
          verifyZipInput(
            input,
            inventory([
              ...files,
              ('missing', [1]),
            ]),
          ),
          throwsFormatException,
        );
        await expectLater(
          verifyZipInput(
            input,
            inventory([
              ...manifest,
              ('payload', [99, 98, 97]),
            ]),
          ),
          throwsFormatException,
        );
      });
      final secondLocal =
          30 +
          'manifest.json'.length +
          ZLibCodec(raw: true).encode(manifest.first.$2).length;
      bytes[secondLocal + 30 + 'payload'.length] = 7;
      await inspect(bytes, (input) async {
        expect(await readZipManifest(input), manifest.first.$2);
        await expectLater(
          verifyZipInput(input, inventory(files)),
          throwsA(isA<Exception>()),
        );
      });
    },
  );
  test('bounds total declared bytes before inflating payloads', () async {
    final files = [
      ...manifest,
      for (var i = 0; i < 5; i++) ('large$i', [1]),
    ];
    final bytes = zip(files);
    var cursor = central(bytes);
    for (var i = 0; i < files.length; i++) {
      final data = ByteData.sublistView(bytes);
      final local = data.getUint32(cursor + 42, Endian.little);
      if (i > 0) {
        set32(bytes, cursor + 24, maxArchiveFileBytes);
        set32(bytes, local + 22, maxArchiveFileBytes);
      }
      cursor += 46 + utf8.encode(files[i].$1).length;
    }
    await expectLater(inspect(bytes, readZipManifest), throwsFormatException);
  });
  test('actual manifest bomb stops at declared bound', () async {
    final bytes = zip([('manifest.json', List.filled(1024 * 1024, 97))]);
    set32(bytes, 22, 2);
    set32(bytes, central(bytes) + 24, 2);
    await expectLater(
      inspect(bytes, readZipManifest),
      throwsA(isA<Exception>()),
    );
  });
  test('native deflate framing parity still requires exact expanded identity', () async {
    final files = [
      ('manifest.json', [97, 98, 99]),
    ];
    // Python zipfile and the native codec accept these equivalent encodings;
    // verification promises exact bounded decoded bytes, not canonical deflate.
    for (final compressed in [
      [75, 76, 74, 6, 0],
      [75, 76, 74, 6],
      [75, 76, 74, 6, 0, 0],
      [75, 76, 74, 6, 0, 75, 76, 74, 6, 0],
    ]) {
      await inspect(zip(files, encode: (_) => compressed), (input) async {
        expect(await readZipManifest(input), [97, 98, 99]);
        await verifyZipInput(input, inventory(files));
        await expectLater(
          verifyZipInput(
            input,
            inventory([
              ('manifest.json', [99, 98, 97]),
            ]),
          ),
          throwsFormatException,
        );
      });
    }
  });
}
