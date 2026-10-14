// Receiver inputs only: real SDK archive, captured diagnostics, synthetic receipts.
// This fixture does not establish SDK validation; export.dart has separate proof.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'pub_stage_fixture.dart';

Future<({PubStageFixture fixture, Directory stage, Directory candidate})>
preparePubCandidateFixture({
  Future<void> Function(PubStageFixture)? beforeStage,
}) async {
  final fixture = await preparePubStageFixture();
  if (beforeStage != null) await beforeStage(fixture);
  final stage = Directory(p.join(fixture.root.path, 'stage'));
  final prepared = await Process.run(Platform.resolvedExecutable, [
    'run',
    'tool/pub/stage.dart',
    '--source',
    fixture.source.path,
    '--descriptor',
    fixture.descriptor.path,
    '--expected-commit',
    fixture.identity['commit'] as String,
    '--output',
    stage.path,
    '--registry-ready',
  ]);
  expect(
    prepared.exitCode,
    0,
    reason: '${prepared.stdout}\n${prepared.stderr}',
  );
  final candidate = Directory(p.join(fixture.root.path, 'candidate'))
    ..createSync();
  final archive = File(p.join(candidate.path, 'pub-package.tar.gz'));
  final exported = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'publish',
    '--directory',
    p.join(stage.path, 'package'),
    '--to-archive',
    archive.path,
    '--skip-validation',
  ]);
  expect(
    exported.exitCode,
    0,
    reason: '${exported.stdout}\n${exported.stderr}',
  );
  final saved = File(p.join(stage.path, 'pub-stage.json'));
  saved.copySync(p.join(candidate.path, 'pub-stage.json'));
  final stageValue = jsonDecode(saved.readAsStringSync()) as Map;
  final execution = Directory(p.join(candidate.path, 'execution'))
    ..createSync();
  final commands = <Map<String, Object?>>[];
  for (var index = 0; index < 3; index++) {
    final command = [
      Platform.resolvedExecutable,
      '--suppress-analytics',
      'pub',
      if (index == 0) ...[
        'get',
        '--offline',
      ] else ...[
        'publish',
        if (index == 1)
          '--dry-run'
        else ...[
          '--to-archive',
          '/fixture/pub-package.tar.gz',
        ],
      ],
    ];
    final stdout = index == 0
        ? utf8.encode('fixture preparation\n')
        : File(
            'test/fixtures/pub-thin-sdk-${index == 1 ? 'dry-run' : 'export'}.txt',
          ).readAsBytesSync();
    final outName = 'installed-$index.stdout.log',
        errName = 'installed-$index.stderr.log';
    File(p.join(execution.path, outName)).writeAsBytesSync(stdout);
    File(p.join(execution.path, errName)).writeAsBytesSync([]);
    final proof = {
      'suite': 'installed-$index',
      'command': command,
      'exit_code': index == 1 ? 65 : 0,
      'timed_out': false,
      'elapsed_seconds': 1,
      'timeout_seconds': 180,
      'stdout': outName,
      'stderr': errName,
      'stdout_sha256': sha256.convert(stdout).toString(),
      'stderr_sha256': sha256.convert([]).toString(),
    };
    File(p.join(execution.path, 'installed-$index.json'))
        .writeAsStringSync(jsonEncode(proof));
    commands.add({
      'arguments': command,
      'exit': proof['exit_code'],
      for (final key in ['stdout', 'stderr', 'stdout_sha256', 'stderr_sha256'])
        key: proof[key],
    });
  }
  final lock = loadYaml(
    File(p.join(fixture.source.path, 'pubspec.lock')).readAsStringSync(),
  ) as Map;
  final dependencies = {
    for (final name in [
      'archive',
      'crypto',
      'ffi',
      'path',
      'posix',
      'tar',
      'unorm_dart',
    ])
      name: {
        'version': lock['packages'][name]['version'],
        'sha256': lock['packages'][name]['description']['sha256'],
        'content_sha256': 'c' * 64,
      },
  };
  File(p.join(candidate.path, 'report.json')).writeAsStringSync(
    jsonEncode({
      'schema_version': 1,
      'source': fixture.identity,
      'stage_sha256': sha256.convert(saved.readAsBytesSync()).toString(),
      'registry_ready': true,
      'dart': '3.13.3',
      'dependencies': dependencies,
      'dry_run': {'exit_code': 65, 'expected_advisories': 7},
      'archive_export': {'exit_code': 0, 'expected_advisories': 7},
      'upload_archive': {
        'size': archive.lengthSync(),
        'sha256': sha256.convert(archive.readAsBytesSync()).toString(),
        'unpacked_bytes': (stageValue['files'] as Map).values.fold<int>(
          0,
          (sum, entry) => sum + (entry['size'] as int),
        ),
        'files': (stageValue['files'] as Map).length,
      },
      'commands': commands,
    }),
  );
  return (fixture: fixture, stage: stage, candidate: candidate);
}
