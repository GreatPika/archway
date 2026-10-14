// Inspect original SDK evidence and materialize its exact upload temporarily.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../ci/release_execution_receipts.dart';
import '../release/archive_input.dart';
import '../validation/json_values.dart';
import 'sdk_advisories.dart';
import 'stage.dart' show pubStageDependencies;
import 'stage_inventory.dart';
import 'upload.dart';

final pubCandidateFiles = Set<String>.unmodifiable(<String>{
  'pub-stage.json',
  'report.json',
  'pub-package.tar.gz',
  for (var index = 0; index < 3; index++) ...[
    'execution/installed-$index.json',
    'execution/installed-$index.stdout.log',
    'execution/installed-$index.stderr.log',
  ],
});
void _require(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

Map<String, Object?> _object(Object? value) {
  _require(value is Map<String, Object?>, 'Expected pub candidate object');
  return value as Map<String, Object?>;
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Future<T> withPubCandidate<T>(
  Directory candidate,
  Directory source,
  Map<String, Object?> identity,
  Future<T> Function(Directory materialized, Map<String, Object?> report)
  inspect,
) async {
  final stage = await readPubStageReceipt(
    candidate,
    identity,
    registryReady: true,
  );
  final report = _object(
    readRecord(File(p.join(candidate.path, 'report.json'))),
  );
  _require(
    report.length == 10 &&
        report['schema_version'] is int &&
        report['schema_version'] == 1 &&
        report['registry_ready'] == true &&
        report['dart'] == '3.13.3' &&
        sameJson(report['source'], identity) &&
        report['stage_sha256'] == stage.sha256,
    'Pub candidate source or SDK identity differs',
  );
  final dependencies = _object(report['dependencies']);
  final lock = loadYaml(
    utf8.decode(
      readOrdinaryBytes(
        File(p.join(source.path, 'pubspec.lock')),
        limit: maxArchiveJsonBytes,
      ),
    ),
  );
  _require(
    lock is Map &&
        lock['packages'] is Map &&
        pubStageDependencies.keys.every(dependencies.containsKey),
    'Pub candidate dependencies are incomplete',
  );
  for (final entry in dependencies.entries) {
    final value = _object(entry.value),
        pinned = (lock as Map)['packages'][entry.key];
    _require(
      value.length == 3 &&
          _digest(value['sha256']) &&
          _digest(value['content_sha256']) &&
          pinned is Map &&
          pinned['source'] == 'hosted' &&
          pinned['description'] is Map &&
          pinned['description']['url'] == 'https://pub.dev' &&
          value['version'] == pinned['version'] &&
          value['sha256'] == pinned['description']['sha256'],
      'Pub candidate dependency pin differs',
    );
  }
  final commands = report['commands'];
  _require(
    commands is List && commands.length == 3,
    'Pub candidate SDK command inventory differs',
  );
  String? dart;
  for (var index = 0; index < 3; index++) {
    final saved = _object((commands as List)[index]);
    final arguments = saved['arguments'];
    _require(
      saved.length == 6 &&
          arguments is List &&
          arguments.every((value) => value is String) &&
          arguments.isNotEmpty,
      'Invalid pub candidate command receipt',
    );
    final command = (arguments as List).cast<String>();
    dart ??= command.first;
    final basename = dart.split(RegExp(r'[/\\]')).last;
    _require(
      ['dart', 'dart.exe'].contains(basename) &&
          (p.posix.isAbsolute(dart) || p.windows.isAbsolute(dart)),
      'Invalid recorded SDK executable',
    );
    final expected = [
      dart,
      '--suppress-analytics',
      'pub',
      if (index == 0) ...[
        'get',
        '--offline',
      ] else ...[
        'publish',
        if (index == 1) '--dry-run' else ...['--to-archive', command.last],
      ],
    ];
    _require(
      sameJson(command, expected) &&
          (index != 2 ||
              command.last.split(RegExp(r'[/\\]')).last ==
                  'pub-package.tar.gz'),
      'Pub candidate SDK command differs',
    );
    final execution = Directory(p.join(candidate.path, 'execution'));
    final original = _object(
      readRecord(File(p.join(execution.path, 'installed-$index.json'))),
    );
    final streams = validateExecution(
      original,
      expected,
      execution,
      p.context,
      suite: 'installed-$index',
      expectedTimeout: 180,
      expectedExit: index == 1 ? 65 : 0,
    );
    _require(
      sameJson(saved, {
        'arguments': expected,
        'exit': original['exit_code'],
        for (final key in [
          'stdout',
          'stderr',
          'stdout_sha256',
          'stderr_sha256',
        ])
          key: original[key],
      }),
      'Pub candidate original command receipt differs',
    );
    if (index > 0) {
      final observed = validatePubAdvisories(
        utf8.decode(streams['stdout']!),
        utf8.decode(streams['stderr']!),
        original['exit_code'] as int,
        version: stage.receipt['version'] as String,
        export: index == 2,
      );
      _require(
        sameJson(observed, report[index == 1 ? 'dry_run' : 'archive_export']),
        'Pub candidate SDK validation differs',
      );
      if (index == 2) {
        _require(
          utf8
              .decode(streams['stdout']!)
              .trimRight()
              .endsWith('Wrote package archive at ${command.last}'),
          'Pub candidate SDK export path differs',
        );
      }
    }
  }
  final upload = _object(report['upload_archive']);
  _require(
    upload.length == 4 &&
        upload['size'] is int &&
        (upload['size'] as int) > 0 &&
        (upload['size'] as int) < pubCompressedLimit &&
        _digest(upload['sha256']) &&
        upload['unpacked_bytes'] is int &&
        upload['files'] is int,
    'Invalid pub SDK archive record',
  );
  final temporary = await candidate.parent.createTemp(
    '.archway-pub-candidate-',
  );
  final materialized = Directory(await temporary.resolveSymbolicLinks());
  try {
    final observed = await inspectPubUpload(
      File(p.join(candidate.path, 'pub-package.tar.gz')),
      stage.files,
      expected: (
        size: upload['size'] as int,
        sha256: upload['sha256'] as String,
      ),
      publishTo: Directory(p.join(materialized.path, 'package')),
    );
    _require(sameJson(observed, upload), 'Pub SDK archive measurements differ');
    await withArchiveInput(File(p.join(candidate.path, 'pub-stage.json')), (
      input,
    ) async {
      _require(
        input.sha256 == stage.sha256,
        'Pub candidate stage receipt changed',
      );
      await input.file.copy(p.join(materialized.path, 'pub-stage.json'));
    });
    await inspectPubStage(materialized, identity, registryReady: true);
    return await inspect(materialized, report);
  } finally {
    await temporary.delete(recursive: true);
  }
}
