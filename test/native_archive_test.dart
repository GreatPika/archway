import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/native_archive.dart';
import 'support/pub_native_fixture.dart';
import 'support/pub_stage_fixture.dart';

const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
final files = {
  'bin/core': {'size': 3, 'mode': 0x1ed, 'sha256': abc},
};

List<int> nativeTar(String manifest, {List<int> payload = const [97, 98, 99]}) {
  final entries = [
    TarEntry.data(TarHeader(name: 'bin/core', mode: 0x1ed), payload),
    TarEntry.data(
      TarHeader(name: 'manifest.json', mode: 0x1a4),
      utf8.encode(manifest),
    ),
  ];
  // TarWriter emits the standard end blocks once for the complete stream.
  return gzip.encode([
    for (final entry in entries)
      ...tarConverter
          .convert(entry)
          .take(512 + ((entry.header.size + 511) ~/ 512) * 512),
    ...List.filled(1024, 0),
  ]);
}

void main() {
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    test(
      'pub native fixture passes strict $target archive verification',
      () async {
        final fixture = await preparePubStageFixture();
        addTearDown(() => fixture.root.deleteSync(recursive: true));
        final archive = preparePubNativeFixture(fixture, target: target);
        final descriptor =
            jsonDecode(fixture.descriptor.readAsStringSync()) as Map;
        final pin = descriptor['targets'][target] as Map;
        final verified = await verifyNativeArchive(
          archive,
          format: target == 'windows-x64'
              ? NativeArchiveFormat.zip
              : NativeArchiveFormat.tarGzip,
          expected: (size: pin['size'] as int, sha256: pin['sha256'] as String),
        );
        expect(verified.manifest['target'], target);
        expect(verified.manifestSha256, pin['manifest_sha256']);
        final name =
            'bin/$target/archway${target == 'windows-x64' ? '.exe' : ''}';
        expect(verified.completeArchiveInventory.files[name]!.mode, 493);
        expect(
          verified.completeArchiveInventory.files['manifest.json']!.mode,
          420,
        );
      },
    );
  }

  late Directory root;
  late Directory snapshots;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('native-archive-')
          .resolveSymbolicLinksSync(),
    );
    snapshots = Directory(p.join(root.path, 'snapshots'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<VerifiedNativeArchive> verify(
    List<int> bytes, {
    ({int size, String sha256})? expected,
  }) {
    final source = File(p.join(root.path, 'input.tar.gz'))
      ..writeAsBytesSync(bytes);
    return verifyNativeArchive(
      source,
      format: NativeArchiveFormat.tarGzip,
      temporaryParent: snapshots,
      expected: expected,
    );
  }

  test('verifies original manifest and archive identities without caller policy', () async {
    final text =
        ' {"source":"caller-owned", "target":"arbitrary", "files":${jsonEncode(files)}}\n';
    final bytes = nativeTar(text);
    final result = await verify(bytes);
    expect(result.manifestBytes, utf8.encode(text));
    expect(result.manifest['source'], 'caller-owned');
    expect(result.archiveSize, bytes.length);
    expect(result.archiveSha256, crypto.sha256.convert(bytes).toString());
    expect(
      result.manifestSha256,
      crypto.sha256.convert(utf8.encode(text)).toString(),
    );
    expect(result.completeArchiveInventory.files['manifest.json'], (
      size: utf8.encode(text).length,
      mode: 0x1a4,
      sha256: result.manifestSha256,
    ));
    expect(result.completeArchiveInventory.files.length, 2);
    expect(snapshots.listSync(), isEmpty);
  });
  test(
    'rejects ambiguous JSON and invalid or incomplete file inventories',
    () async {
      for (final text in [
        '{"files":{},"f\\u0069les":${jsonEncode(files)}}',
        '{"files":[]}',
        jsonEncode({
          'files': {
            'bin/core': {'size': 3, 'mode': 493, 'sha256': 'z' * 64},
          },
        }),
        jsonEncode({
          'files': {'missing': files['bin/core']},
        }),
        '{"files":${jsonEncode(files)},"number":1e999}',
      ]) {
        await expectLater(
          verify(nativeTar(text)),
          throwsFormatException,
          reason: text,
        );
        expect(snapshots.listSync(), isEmpty);
      }
    },
  );

  test(
    'rejects changed payload, oversized manifest and wrong compressed pin',
    () async {
      final text = jsonEncode({'files': files});
      await expectLater(
        verify(nativeTar(text, payload: [97, 98, 100])),
        throwsFormatException,
      );
      final zip = archive.Archive()
        ..addFile(
          archive.ArchiveFile.bytes('bin/core', [97, 98, 100])..mode = 0x81ed,
        )
        ..addFile(
          archive.ArchiveFile.bytes('manifest.json', utf8.encode(text))
            ..mode = 0x81a4,
        );
      final source = File(p.join(root.path, 'input.zip'))
        ..writeAsBytesSync(archive.ZipEncoder().encode(zip));
      await expectLater(
        verifyNativeArchive(
          source,
          format: NativeArchiveFormat.zip,
          temporaryParent: snapshots,
        ),
        throwsFormatException,
      );
      await expectLater(
        verify(nativeTar(' ' * maxArchiveJsonBytes + text)),
        throwsFormatException,
      );
      final bytes = nativeTar(text);
      await expectLater(
        verify(bytes, expected: (size: bytes.length, sha256: '0' * 64)),
        throwsFormatException,
      );
      expect(snapshots.listSync(), isEmpty);
    },
  );

  test(
    'returned manifest bytes, nested objects and arrays are immutable',
    () async {
      final result = await verify(
        nativeTar(
          jsonEncode({
            'files': files,
            'extra': [
              {'nested': true},
            ],
          }),
        ),
      );
      expect(() => result.manifestBytes[0] = 0, throwsUnsupportedError);
      expect(() => result.manifest['extra'] = null, throwsUnsupportedError);
      expect(
        () => (result.manifest['files'] as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (result.manifest['extra'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => ((result.manifest['extra'] as List).first as Map).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => result.completeArchiveInventory.files.clear(),
        throwsUnsupportedError,
      );
    },
  );
  // Python release_bundles.write_json/inventory/zip_tree and the build() PAX
  // tarfile loop generated these original fixtures. Legacy verify_bundle passed.
  // Each contains café.txt (abc, 0755), a 0644 manifest and fractional PAX mtime.
  test('existing Python producer ZIP and PAX gzip fixtures verify', () async {
    final fixtures = <NativeArchiveFormat, String>{
      NativeArchiveFormat.zip:
          'UEsDBBQAAAgIANRt41jCQSQ1BQAAAAMAAAAJAAAAY2Fmw6kudHh0S0xKBgBQSwMEFAAAAAgA1G3jWD5EmAKqAAAA'
          '+AAAAA0AAABtYW5pZmVzdC5qc29uRY/dCoMwDIXvfYrSazfSVqvdq2y7iDZlglPQymTiuy865ggE8p38nCyJEJLm'
          'OKC8iCsXQix7ZtzRGMkzj8NEO1w539NtJDQtjSx9m2WN4TYBkDvHOR6YhWfvievMmfSHxgfq3DKUFRalslUoA6g6'
          'EGaKAzzlHklrbSoAYxUaZ1VRoKurTEEIVgUNoHL08r+zeW9nzOFy3V2O/TTUm8AG25aGU//q+KNkTT5QSwECFAMU'
          'AAAICADUbeNYwkEkNQUAAAADAAAACQAAAAAAAAAAAAAA7YEAAAAAY2Fmw6kudHh0UEsBAhQDFAAAAAgA1G3jWD5E'
          'mAKqAAAA+AAAAA0AAAAAAAAAAAAAAKSBLAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAIAAgByAAAAAQEAAAAA',
      NativeArchiveFormat.tarGzip:
          'H4sICHxszmoC/2ZpeHR1cmUudGFyAO3W3U7CMBQA4F3zFM2ucfR07QomRC+99F696LZWZtgw+4mLhAfyOXwxzwDR'
          'aNArFoXzLVm300EL/TkLRsHo8tq0V9aktvQOgm/sKzlX8HHdxYELAI+1Xg+aqjYlNu+dJhizR1PPpolxry9B3dYD'
          'EbK8znI7BS22IxIINfDIMcJxv+iG/ZBtdFNIK9WVoBX/XG6FHshIggC9Wf8glfQY73P9m3tb/PQv/Fb/T5k4oUVw'
          'woK/kP+F/p7/JeX/PlC2P225KTJnqzp4qBbFAfN/JOXe/B9q/iX/C4Uhyv89WA4Y821bl8Y/Zzd4w9hyfcZwgfPC'
          'phivy8augys83w27j7hsbius2jzs42vkbcO5nXTvkrswVuSL1OK9nITD91A1M0JFGPRjo8cQxW7sOCTOGgl48NSq'
          '1FghRBjj3IjAhJMItDaTJJbAnYvA4VYFyqT+x3dmz10z4a6Xq3Uvq0VTJl0FdnA+t+XZ4qnAXzRY0QZHCCGEEEII'
          'IYQQQgghhJCj9QYQSnvoACgAAA==',
    };
    for (final entry in fixtures.entries) {
      final bytes = base64Decode(entry.value);
      final source = File(p.join(root.path, 'producer'))
        ..writeAsBytesSync(bytes);
      final result = await verifyNativeArchive(
        source,
        format: entry.key,
        temporaryParent: snapshots,
      );
      expect(result.completeArchiveInventory.files['café.txt'], (
        size: 3,
        mode: 0x1ed,
        sha256: abc,
      ));
      expect(result.archiveSha256, crypto.sha256.convert(bytes).toString());
      expect(result.manifest['source'], 'caller-owned');
      expect(snapshots.listSync(), isEmpty);
    }
  });
}
