// Physical same-source thin-stage fixture; native pins are synthetic, not hosted proof.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/release/installation_identity.dart';

const pubRuntimeFixtureFiles = [
  'tool/pub/download.dart',
  'tool/pub/native_cache.dart',
  'tool/pub/launcher.dart',
  'tool/release/archive_extraction.dart',
  'tool/release/archive_input.dart',
  'tool/release/gzip_input.dart',
  'tool/release/tar_input.dart',
  'tool/release/zip_input.dart',
  'tool/release/native_manifest.dart',
  'tool/release/native_archive.dart',
  'tool/release/publish_directory.dart',
  'tool/release/strict_json.dart',
  'tool/validation/json_values.dart',
];

typedef PubStageFixture = ({
  Directory root,
  Directory source,
  File descriptor,
  Map<String, Object> identity,
});
Future<PubStageFixture> preparePubStageFixture() async {
  final root = Directory(
    Directory.systemTemp
        .createTempSync('pub stage café-')
        .resolveSymbolicLinksSync(),
  );
  final source = Directory(p.join(root.path, 'source'))..createSync();
  void write(String name, String value) {
    final file = File(p.join(source.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(value);
  }

  for (final name in pubRuntimeFixtureFiles) {
    write(name, File(name).readAsStringSync());
  }
  write('LICENSE', 'fixture license\n');
  write('CHANGELOG.md', '# Changelog\n\n## 0.2.0\n\n- Thin wrapper fixture.\n');
  write(
    'pubspec.yaml',
    'name: archway\nversion: 0.2.0\nrepository: https://github.com/GreatPika/archway\nenvironment:\n  sdk: ">=3.13.3 <4.0.0"\ndependencies:\n  crypto: 3.0.7\n  path: 1.9.1\n  unorm_dart: 0.3.2\ndev_dependencies:\n  archive: 4.5.2\n  ffi: 2.2.0\n  posix: 6.5.2\n  tar: 2.0.3\n',
  );
  write('pubspec.lock', File('pubspec.lock').readAsStringSync());
  write('assets/typescript/package-lock.json', '{}');
  // Files that must never enter the thin package, despite being tracked.
  write('lib/core.dart', 'core source');
  write('bin/setup.dart', 'legacy repair');
  for (final args in [
    ['init', '-q'],
    ['add', '.'],
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
  final descriptor = File(p.join(root.path, 'acquisition.json'))
    ..writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'version': '0.2.0',
        'source': identity,
        'targets': {
          for (final target in ['linux-x64', 'macos-arm64', 'windows-x64'])
            target: {
              'url':
                  'https://github.com/GreatPika/archway/releases/download/v0.2.0/archway-0.2.0-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}',
              'size': 123,
              'sha256': 'a' * 64,
              'manifest_sha256': 'b' * 64,
            },
        },
      }),
    );
  return (
    root: root,
    source: source,
    descriptor: descriptor,
    identity: identity,
  );
}
