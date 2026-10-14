import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../tool/release/installation_identity.dart';

Future<
  ({
    Directory root,
    Directory source,
    Map<String, Object> identity,
    File descriptor,
  })
>
prepareNpmStageFixture() async {
  final repository = Directory.current.path;
  final root = Directory(
    Directory.systemTemp
        .createTempSync('npm stage café ')
        .resolveSymbolicLinksSync(),
  );
  final source = Directory(p.join(root.path, 'source'))..createSync();
  for (final name in [
    'pubspec.yaml',
    'pubspec.lock',
    'assets/typescript/package-lock.json',
    'LICENSE',
    'CHANGELOG.md',
    'tool/npm/README.md',
    'tool/npm/package.json',
    'tool/npm/package-lock.json',
    for (final name in ['archway', 'archive', 'cache', 'download', 'inventory'])
      'tool/npm/$name.cjs',
  ]) {
    final output = File(p.join(source.path, name));
    output.parent.createSync(recursive: true);
    File(p.join(repository, name)).copySync(output.path);
  }
  final pubspec = File(p.join(source.path, 'pubspec.yaml'));
  pubspec.writeAsStringSync(
    pubspec.readAsStringSync().replaceFirst(
      RegExp(r'^version:.*$', multiLine: true),
      'version: 1.2.3',
    ),
  );
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
      'canonical wrapper fixture',
    ],
  ]) {
    final git = Process.runSync('git', ['-C', source.path, ...args]);
    if (git.exitCode != 0) throw StateError('${git.stderr}');
  }
  final identity = await sourceIdentity(source);
  final descriptor = File(p.join(root.path, 'acquisition.json'))
    ..writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'version': '1.2.3',
        'source': identity,
        'targets': {
          for (final target in ['linux-x64', 'macos-arm64', 'windows-x64'])
            target: {
              'url':
                  'https://github.com/GreatPika/archway/releases/download/v1.2.3/archway-1.2.3-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}',
              'size': 100,
              'sha256': 'a' * 64,
              'manifest_sha256': 'b' * 64,
            },
        },
      }),
    );

  return (
    root: root,
    source: source,
    identity: identity,
    descriptor: descriptor,
  );
}
