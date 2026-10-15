import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/native_release_fixture.dart';
import '../tool/release/native_archive.dart';

void main() {
  test('native archives precede wrappers and preserve target bytes reproducibly', () async {
    final fixture = await prepareNativeReleaseFixture();
    final root = fixture.root,
        guide = fixture.guide,
        identity = fixture.identity,
        payloads = fixture.payloads;
    addTearDown(() => root.deleteSync(recursive: true));
    Future<ProcessResult> build(String name) =>
        buildNativeFixture(fixture, name);
    final first = await build('one');
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final second = await build('two');
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    final receipt = jsonDecode(
      File(p.join(root.path, 'one/native-packaging.json')).readAsStringSync(),
    ) as Map;
    expect(receipt['version'], '1.2.3');
    expect(receipt['source'], identity);
    final checksum = File(p.join(root.path, 'one/SHA256SUMS'));
    expect(
      checksum.existsSync(),
      isTrue,
      reason: 'Native host consumer requires the producer checksum file',
    );
    const names = [
      'archway-1.2.3-linux-x64.tar.gz',
      'archway-1.2.3-macos-arm64.tar.gz',
      'archway-1.2.3-windows-x64.zip',
    ];
    expect(
      checksum.readAsStringSync(),
      names
          .map(
            (name) =>
                '${sha256.convert(File(p.join(root.path, 'one', name)).readAsBytesSync())}  $name\n',
          )
          .join(),
    );

    for (final target in payloads.keys) {
      final name =
          'archway-1.2.3-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
      final file = File(p.join(root.path, 'one', name));
      expect(
        file.readAsBytesSync(),
        File(p.join(root.path, 'two', name)).readAsBytesSync(),
      );
      final verified = await verifyNativeArchive(
        file,
        format: target == 'windows-x64'
            ? NativeArchiveFormat.zip
            : NativeArchiveFormat.tarGzip,
      );
      final original = File(
        p.join(fixture.transports.path, target, 'provenance.json'),
      );
      final originalFiles =
          (jsonDecode(original.readAsStringSync()) as Map)['files'] as Map;
      final finalFiles = verified.manifest['files'] as Map;
      for (final entry in originalFiles.entries) {
        expect(
          finalFiles[entry.key],
          entry.value,
          reason: 'Preserve original payload ${entry.key}',
        );
      }
      for (final evidence in ['provenance.json', 'installation.tar']) {
        expect(
          File(p.join(root.path, 'one/evidence/original', target, evidence))
              .readAsBytesSync(),
          File(p.join(fixture.transports.path, target, evidence))
              .readAsBytesSync(),
        );
      }
      expect(
        (receipt['native_bundles'] as Map)[target]['size'],
        file.lengthSync(),
      );
      expect(
        (receipt['native_bundles'] as Map)[target]['sha256'],
        sha256.convert(file.readAsBytesSync()).toString(),
      );
      expect(verified.manifest['target'], target);
      expect(verified.manifest['versions'], {
        'archway': '1.2.3',
        'dart': '3.13.3',
        'node': '24.21.0',
        'typescript': '5.9.3',
        'yaml': '2.8.1',
      });
      expect(
        (receipt['native_bundles'] as Map)[target]['manifest_sha256'],
        verified.manifestSha256,
      );
      expect(
        verified.completeArchiveInventory.files['README.txt']!.sha256,
        sha256.convert(guide.readAsBytesSync()).toString(),
      );
    }
  });
  for (final row in <(String, void Function(Map), String)>[
    (
      'source',
      (record) => (record['source'] as Map)['commit'] = '0' * 40,
      'Transport source or target mismatch',
    ),
    (
      'target',
      (record) => record['target'] = 'windows-x64',
      'Transport source or target mismatch',
    ),
    (
      'archive',
      (record) => (record['archive'] as Map)['sha256'] = '0' * 64,
      'Archive identity mismatch',
    ),
    (
      'missing-analysis',
      (record) => (record['runtimes'] as Map).remove('analysis_dart'),
      'Invalid transport runtime evidence',
    ),
    (
      'runtime',
      (record) => (record['runtimes'] as Map)['build_dart'] =
          'Dart SDK version: 3.13.4 (stable)',
      'Analysis Dart differs from build runtime',
    ),
  ]) {
    test(
      'native producer refuses changed ${row.$1} evidence without publishing partial output',
      () async {
        final fixture = await prepareNativeReleaseFixture();
        addTearDown(() => fixture.root.deleteSync(recursive: true));
        final path = File(
          p.join(fixture.transports.path, 'linux-x64/provenance.json'),
        );
        final original = path.readAsBytesSync();
        final record = jsonDecode(utf8.decode(original)) as Map;
        row.$2(record);
        path.writeAsStringSync(jsonEncode(record));
        final result = await buildNativeFixture(fixture, 'refused-${row.$1}');
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains(row.$3));
        expect(
          Directory(p.join(fixture.root.path, 'refused-${row.$1}'))
              .existsSync(),
          false,
        );
        expect(
          fixture.root.listSync().where(
            (entry) => p.basename(entry.path).startsWith('.archway-native-'),
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'native producer refuses an existing output without changing it',
    () async {
      final fixture = await prepareNativeReleaseFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final existing = Directory(p.join(fixture.root.path, 'existing'))
        ..createSync();
      final sentinel = File(p.join(existing.path, 'keep'))
        ..writeAsStringSync('unchanged');
      final refusal = await buildNativeFixture(fixture, 'existing');
      expect(refusal.exitCode, isNot(0));
      expect(refusal.stderr, contains('Native output already exists'));
      expect(sentinel.readAsStringSync(), 'unchanged');
    },
  );
  test(
    'rejects prepared compiler version that differs from the source lock',
    () async {
      final fixture = await prepareNativeReleaseFixture(
        typescriptVersion: '5.8.0',
      );
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final result = await buildNativeFixture(fixture, 'wrong-compiler');
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Prepared vendor version differs from source'),
      );
      expect(
        Directory(p.join(fixture.root.path, 'wrong-compiler')).existsSync(),
        false,
      );
    },
  );
  test('refuses a transport missing a prepared compiler library', () async {
    final fixture = await prepareNativeReleaseFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    File(
      p.join(
        fixture.source.path,
        'assets/typescript/vendor/typescript/lib/lib.dom.d.ts',
      ),
    ).writeAsStringSync('independent expected library');
    final result = await buildNativeFixture(fixture, 'incomplete-vendor');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Unexpected staged asset inventory'));
    expect(
      Directory(p.join(fixture.root.path, 'incomplete-vendor')).existsSync(),
      false,
    );
  });
  test('rejects coherently unpinned runtime evidence', () async {
    final fixture = await prepareNativeReleaseFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    for (final runtime in ['node', 'dart']) {
      for (final target in fixture.payloads.keys) {
        final file = File(
          p.join(fixture.transports.path, target, 'provenance.json'),
        );
        final record = jsonDecode(file.readAsStringSync()) as Map;
        final runtimes = record['runtimes'] as Map;
        runtimes['build_dart'] =
            'Dart SDK version: ${runtime == 'dart' ? '3.13.4' : '3.13.3'} (stable)';
        if (target != 'windows-x64') {
          runtimes['analysis_dart'] = runtimes['build_dart'];
          runtimes['analysis_node'] = runtime == 'node'
              ? 'v24.22.0'
              : 'v24.21.0';
        }
        file.writeAsStringSync(jsonEncode(record));
      }
      final result = await buildNativeFixture(fixture, 'unpinned-$runtime');
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Observed runtimes differ from release pins'),
      );
    }
  });
}
