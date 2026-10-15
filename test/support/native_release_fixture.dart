// Independent physical transport fixtures; payloads are synthetic, never host proof.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../../tool/release/installation_identity.dart';

typedef NativeReleaseFixture = ({
  Directory root,
  Directory source,
  Directory transports,
  File guide,
  Map<String, Object> identity,
  Map<String, String> payloads,
});
Future<NativeReleaseFixture> prepareNativeReleaseFixture({
  String typescriptVersion = '5.9.3',
}) async {
  final root = Directory(
    Directory.systemTemp
        .createTempSync('native-first café-')
        .resolveSymbolicLinksSync(),
  );
  final source = Directory(p.join(root.path, 'source'))..createSync();
  void write(String name, String text) {
    final file = File(p.join(source.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  write(
    'pubspec.yaml',
    'name: archway\nversion: 1.2.3\nrepository: https://github.com/GreatPika/archway\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n',
  );
  write('pubspec.lock', 'fixture lock\n');
  write(
    'assets/typescript/package-lock.json',
    jsonEncode({
      'packages': {
        'node_modules/typescript': {'version': '5.9.3'},
        'node_modules/yaml': {'version': '2.8.1'},
      },
    }),
  );
  write('assets/typescript/helper.cjs', 'synthetic helper');
  for (final name in [
    'licenses/pnpm-MIT.txt',
    'licenses/yaml-ISC.txt',
    'vendor/typescript/package.json',
    'vendor/typescript/lib/typescript.js',
    'vendor/typescript/lib/lib.es2022.d.ts',
    'vendor/typescript/LICENSE.txt',
    'vendor/yaml/package.json',
    'vendor/yaml/dist/index.js',
    'vendor/yaml/LICENSE',
  ]) {
    write('assets/typescript/$name', 'synthetic asset $name');
  }
  write(
    'assets/typescript/vendor/typescript/package.json',
    jsonEncode({'version': typescriptVersion}),
  );
  write(
    'assets/typescript/vendor/yaml/package.json',
    jsonEncode({'version': '2.8.1'}),
  );
  for (final name in ['policy', 'public-result', 'export-diagnostics']) {
    write('contracts/json/$name.schema.json', '{}\n');
  }
  write('LICENSE', 'synthetic license\n');
  for (final args in [
    ['init', '-q'],
    ['add', '.'],
    ['reset', '-q', '--', 'assets/typescript/vendor'],
    [
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-qm',
      'fixture',
    ],
  ]) {
    expect(Process.runSync('git', ['-C', source.path, ...args]).exitCode, 0);
  }
  final identity = await sourceIdentity(source);
  final transports = Directory(p.join(root.path, 'transports'))..createSync();
  final payloads = {
    'linux-x64': 'libarchway_io.so',
    'macos-arm64': 'libarchway_io.dylib',
    'windows-x64': 'archway_io.dll',
  };
  for (final target in payloads.keys) {
    final data = <String, List<int>>{};
    for (final file in Directory(
      p.join(source.path, 'assets/typescript'),
    ).listSync(recursive: true).whereType<File>()) {
      data[p
          .relative(file.path, from: source.path)
          .split(p.separator)
          .join('/')] = file
          .readAsBytesSync();
    }
    data['bin/$target/archway${target == 'windows-x64' ? '.exe' : ''}'] = utf8
        .encode('synthetic binary $target');
    data['native/$target/${payloads[target]}'] = utf8.encode(
      'synthetic bridge $target',
    );
    final files = {
      for (final entry in data.entries)
        entry.key: {
          'size': entry.value.length,
          'mode': target == 'windows-x64'
              ? 438
              : entry.key.startsWith('bin/')
              ? 493
              : 420,
          'sha256': sha256.convert(entry.value).toString(),
        },
    };
    final directory = Directory(p.join(transports.path, target))..createSync();
    final tar = File(p.join(directory.path, 'installation.tar'));
    await Stream<TarEntry>.fromIterable(
      data.entries.map(
        (entry) => TarEntry.data(
          TarHeader(name: entry.key, mode: files[entry.key]!['mode'] as int),
          entry.value,
        ),
      ),
    ).transform(tarWriter).pipe(tar.openWrite());
    File(p.join(directory.path, 'provenance.json')).writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'source': identity,
        'target': target,
        'host': {
          'system': target == 'windows-x64'
              ? 'Windows'
              : target == 'linux-x64'
              ? 'Linux'
              : 'Darwin',
          'machine': target == 'windows-x64'
              ? 'AMD64'
              : target == 'linux-x64'
              ? 'x86_64'
              : 'arm64',
          'release': 'fixture',
        },
        'checks': {
          'profile': target == 'windows-x64' ? 'init-only' : 'process',
          'suites': target == 'windows-x64'
              ? <String>[]
              : [
                  'native_asset_process_smoke.dart',
                  'cli_process_smoke.dart',
                  'dart_check_process_smoke.dart',
                  'alias_trace_gap_process_smoke.dart',
                ],
          'relocated_init': true,
          'transported_init': true,
        },
        'runtimes': {
          'build_dart': 'Dart SDK version: 3.13.3 (stable)',
          if (target != 'windows-x64') ...{
            'analysis_node': 'v24.21.0',
            'analysis_dart': 'Dart SDK version: 3.13.3 (stable)',
          },
        },
        'files': files,
        'archive': {
          'name': 'installation.tar',
          'sha256': sha256.convert(tar.readAsBytesSync()).toString(),
        },
      }),
    );
  }
  final guide = File(p.join(root.path, 'guide.txt'))
    ..writeAsStringSync('Read before use.\n');
  return (
    root: root,
    source: source,
    transports: transports,
    guide: guide,
    identity: identity,
    payloads: payloads,
  );
}

Future<ProcessResult> buildNativeFixture(
  NativeReleaseFixture fixture,
  String name,
) => Process.run(Platform.resolvedExecutable, [
  'run',
  'tool/release/build_native_archives.dart',
  '--source',
  fixture.source.path,
  '--transports',
  fixture.transports.path,
  '--guide',
  fixture.guide.path,
  '--expected-commit',
  fixture.identity['commit'] as String,
  '--output',
  p.join(fixture.root.path, name),
]);
