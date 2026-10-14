// Real SDK validation and archive export; no authentication or publication.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../ci/installed_command_recorder.dart';
import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import '../validation/json_values.dart';
import 'dependency_identity.dart';
import 'sdk_advisories.dart';
import 'stage_inventory.dart';
import 'upload.dart';

Future<void> exportPub({
  required Directory stage,
  required Directory source,
  required Directory cache,
  required Directory evidence,
  required Directory output,
  required String expectedCommit,
}) async {
  if (Platform.version.split(' ').first != '3.13.3') {
    throw const FormatException('Pub export requires Dart 3.13.3');
  }
  if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('Pub export output already exists');
  }
  if (source.resolveSymbolicLinksSync() != source.absolute.path) {
    throw const FormatException('Expected canonical SDK export source');
  }
  final identity = await sourceIdentity(source);
  if (identity['commit'] != expectedCommit)
    throw const FormatException('Pub export source differs');
  final checked = await inspectPubStage(stage, identity, registryReady: true);
  final environment = Map<String, String>.from(Platform.environment)
    ..['PUB_CACHE'] = cache.absolute.path
    ..['PUB_HOSTED_URL'] = 'https://pub.dev';
  if (cache.resolveSymbolicLinksSync() != cache.absolute.path) {
    throw const FormatException('Expected canonical prepared pub cache');
  }
  if (FileSystemEntity.typeSync(evidence.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('SDK evidence output already exists');
  }
  await evidence.create(recursive: true);
  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.archway-pub-export-');
  var published = false;
  try {
    final working = Directory(p.join(temporary.path, 'working'))..createSync();
    for (final entry in checked.files.files.entries) {
      await withArchiveInput(
        File(p.joinAll([stage.path, 'package', ...entry.key.split('/')])),
        (input) async {
          final destination = File(p.join(working.path, entry.key));
          destination.parent.createSync(recursive: true);
          await input.file.copy(destination.path);
        },
        expected: (size: entry.value.size, sha256: entry.value.sha256),
      );
    }
    final recorder = InstalledCommandRecorder(
      output: evidence,
      timeout: const Duration(seconds: 180),
    );
    final dart = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    await recorder.capture(
      [dart, '--suppress-analytics', 'pub', 'get', '--offline'],
      workingDirectory: working.path,
      environment: environment,
    );
    final lock = File(p.join(working.path, 'pubspec.lock'));
    final canonicalLock = File(p.join(source.path, 'pubspec.lock'));
    final dependencies = await pubDependencyIdentity(
      lock,
      canonicalLock,
      cache,
    );
    Future<Map<String, Object>> execute(bool export) async {
      final result = await recorder.capture(
        [
          dart,
          '--suppress-analytics',
          'pub',
          'publish',
          if (export) ...[
            '--to-archive',
            p.join(temporary.path, 'pub-package.tar.gz'),
          ] else
            '--dry-run',
        ],
        workingDirectory: working.path,
        environment: environment,
        expectedExit: export ? 0 : 65,
      );
      return validatePubAdvisories(
        utf8.decode(result.stdout),
        utf8.decode(result.stderr),
        result.exitCode,
        version: checked.receipt['version'] as String,
        export: export,
      );
    }

    final dryRun = await execute(false);
    final archiveExport = await execute(true);
    if (!sameJson(
      dependencies,
      await pubDependencyIdentity(lock, canonicalLock, cache),
    )) {
      throw const FormatException('Dependency bytes changed during SDK export');
    }
    final upload = await inspectPubUpload(
      File(p.join(temporary.path, 'pub-package.tar.gz')),
      checked.files,
    );
    final after = await inspectPubStage(stage, identity, registryReady: true);
    if (after.sha256 != checked.sha256 ||
        !sameJson(identity, await sourceIdentity(source))) {
      throw const FormatException(
        'Source or immutable pub stage changed during export',
      );
    }
    await withArchiveInput(File(p.join(stage.path, 'pub-stage.json')), (
      input,
    ) async {
      if (input.sha256 != checked.sha256)
        throw const FormatException('Pub stage receipt changed');
      await input.file.copy(p.join(temporary.path, 'pub-stage.json'));
    });
    final logs = Directory(p.join(temporary.path, 'execution'))..createSync();
    for (final entry in evidence.listSync()) {
      if (entry is! File)
        throw const FormatException('Unexpected SDK evidence entry');
      await entry.copy(p.join(logs.path, p.basename(entry.path)));
    }
    File(p.join(temporary.path, 'report.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'source': identity, 'stage_sha256': checked.sha256, 'registry_ready': true, 'dart': '3.13.3', 'dependencies': dependencies, 'dry_run': dryRun, 'archive_export': archiveExport, 'upload_archive': upload, 'commands': recorder.commands})}\n',
    );
    await working.delete(recursive: true);
    publishDirectory(temporary, output);
    published = true;
  } finally {
    if (!published) await temporary.delete(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser();
    for (final name in [
      'stage',
      'source',
      'pub-cache',
      'evidence',
      'output',
      'expected-commit',
    ]) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty)
      throw const FormatException('Unexpected SDK export arguments');
    await exportPub(
      stage: Directory(args['stage'] as String).absolute,
      source: Directory(args['source'] as String).absolute,
      cache: Directory(args['pub-cache'] as String).absolute,
      evidence: Directory(args['evidence'] as String).absolute,
      output: Directory(args['output'] as String).absolute,
      expectedCommit: args['expected-commit'] as String,
    );
    stdout.writeln(
      'Validated and exported SDK pub archive; no publication performed.',
    );
  } catch (error) {
    stderr.writeln('Pub SDK export refused: $error');
    exitCode = 1;
  }
}
