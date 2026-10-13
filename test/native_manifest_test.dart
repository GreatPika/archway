import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';

import '../tool/release/native_manifest.dart';

const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const text =
    ' {"source":"caller-owned","target":"arbitrary","version":null,'
    '"files":{"bin/core":{"size":3,"mode":493,"sha256":"$abc"}},'
    '"extra":[{"nested":true}]}\n';

class OversizedBytes extends ListBase<int> {
  @override
  int get length => maxArchiveJsonBytes + 1;
  @override
  set length(int value) => throw StateError('Must check bound first');
  @override
  int operator [](int index) => throw StateError('Must check bound first');
  @override
  void operator []=(int index, int value) =>
      throw StateError('Immutable input');
}

void main() {
  test(
    'reads an ordinary manifest without requiring any payload files',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('native-manifest-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final source = File(p.join(root.path, 'manifest.json'))
        ..writeAsStringSync(text);
      final result = await readNativeManifest(source);
      expect(result.manifestBytes, utf8.encode(text));
      expect(result.completeArchiveInventory.files.keys, [
        'bin/core',
        'manifest.json',
      ]);
    },
  );
  test('bounds direct input before reading or decoding bytes', () {
    expect(() => parseNativeManifest(OversizedBytes()), throwsFormatException);
  });
  test('parses original bytes and inventory without caller policy', () {
    final bytes = utf8.encode(text);
    final result = parseNativeManifest(bytes);
    expect(result.manifestBytes, bytes);
    expect(
      result.manifestSha256,
      'b8e9e9ffd9ac996d68ea535cde9c0258126bece0702899f6c78e86bf61a19dc3',
    );
    expect(result.manifest['source'], 'caller-owned');
    expect(result.manifest['target'], 'arbitrary');
    expect(result.manifest['version'], isNull);
    expect(result.completeArchiveInventory.files['bin/core'], (
      size: 3,
      mode: 493,
      sha256: abc,
    ));
    expect(result.completeArchiveInventory.files['manifest.json'], (
      size: bytes.length,
      mode: 420,
      sha256: result.manifestSha256,
    ));
    expect(result.completeArchiveInventory.files.length, 2);
  });
  test('retains no mutable bytes, objects, arrays or inventory', () {
    final bytes = utf8.encode(text);
    final result = parseNativeManifest(bytes);
    bytes[0] = 0;
    expect(result.manifestBytes, utf8.encode(text));
    expect(() => result.manifestBytes.clear(), throwsUnsupportedError);
    expect(() => result.manifest.clear(), throwsUnsupportedError);
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
  });
  test(
    'rejects ambiguous JSON and malformed inventory before payload checks',
    () {
      for (final invalid in [
        '[]',
        '{"files":{}}',
        '{"files":[],"files":{}}',
        text.replaceFirst('"files":', '"f\\u0069les":{},"files":'),
        text.replaceFirst('"size":3', '"size":3.0'),
        text.replaceFirst('"size":3', '"size":true'),
        text.replaceFirst('"mode":493', '"mode":33261'),
        text.replaceFirst('"sha256":', '"extra":1,"sha256":'),
        text.replaceFirst(abc, 'f' * 63),
        text.replaceFirst('bin/core', '../core'),
        text.replaceFirst('bin/core', 'manifest.json'),
        text.replaceFirst('"size":3', '"size":-1'),
        '$text null',
      ]) {
        expect(
          () => parseNativeManifest(utf8.encode(invalid)),
          throwsFormatException,
          reason: invalid,
        );
      }
      expect(() => parseNativeManifest([0xff]), throwsFormatException);
    },
  );
  test('accepts exactly the byte bound and rejects one byte beyond it', () {
    final bytes = utf8.encode(text);
    final atBound = [
      ...bytes,
      ...List.filled(maxArchiveJsonBytes - bytes.length, 32),
    ];
    expect(
      parseNativeManifest(atBound).manifestBytes.length,
      maxArchiveJsonBytes,
    );
    expect(() => parseNativeManifest([...atBound, 32]), throwsFormatException);
  });
  test('file reads reject oversized, nonregular and aliased inputs', () async {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('native-manifest-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(root.path, 'manifest.json'))
      ..writeAsStringSync(text);
    await expectLater(
      readNativeManifest(File(root.path)),
      throwsFormatException,
    );
    final alias = Link(p.join(root.path, 'alias'))..createSync(source.path);
    await expectLater(
      readNativeManifest(File(alias.path)),
      throwsFormatException,
    );
    final handle = source.openSync(mode: FileMode.write);
    handle.truncateSync(maxArchiveJsonBytes + 1);
    handle.closeSync();
    await expectLater(readNativeManifest(source), throwsFormatException);
  });
}
