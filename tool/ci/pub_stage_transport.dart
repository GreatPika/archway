// Private thin-stage transport; caller-pinned identity never comes from a neighbor.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../pub/stage_inventory.dart';
import '../pub/candidate.dart';
import '../release/archive_input.dart';
import '../release/installation_artifact.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import '../release/strict_json.dart';
import '../release/tar_input.dart';
import '../validation/json_values.dart';

void _require(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
Map<String, Object?> _object(Object? value) {
  _require(value is Map<String, Object?>, 'Expected transport object');
  return value as Map<String, Object?>;
}

Future<Map<String, Object>> _source(Directory source, String commit) async {
  _require(
    source.resolveSymbolicLinksSync() == source.absolute.path,
    'Expected canonical transport source',
  );
  final identity = await sourceIdentity(source);
  _require(
    identity['commit'] == commit,
    'Transport source differs from expected commit',
  );
  return identity;
}

ArchiveInventory admitPubTransportRecord(
  Map<String, Object?> record,
  String commit,
  String run,
  String attempt,
  bool registryReady,
) {
  _require(
    record.length == (registryReady ? 9 : 8) &&
        record['schema_version'] is int &&
        record['schema_version'] == (registryReady ? 2 : 1) &&
        record['registry_ready'] == registryReady &&
        _digest(record['stage_sha256']),
    'Transport schema or explicit registry intent differs',
  );
  final source = _object(record['source']);
  final runPattern = RegExp(r'^[1-9][0-9]{0,19}$');
  _require(
    source['commit'] == commit &&
        runPattern.hasMatch(run) &&
        runPattern.hasMatch(attempt) &&
        record['run_id'] == run &&
        record['run_attempt'] == attempt,
    'Transport differs from current source/run/attempt',
  );
  final archive = _object(record['archive']);
  _require(
    archive.length == 2 &&
        archive['size'] is int &&
        (archive['size'] as int) > 0 &&
        (archive['size'] as int) <= maxArchiveBytes &&
        _digest(archive['sha256']),
    'Invalid transport archive pin',
  );
  final files = _object(record['files']);
  _require(
    registryReady
        ? files.length == pubCandidateFiles.length &&
              pubCandidateFiles.every(files.containsKey)
        : files.containsKey('pub-stage.json') &&
              files.keys.every(
                (name) =>
                    name == 'pub-stage.json' || name.startsWith('package/'),
              ),
    'Unexpected thin transport inventory',
  );
  if (registryReady) _object(record['upload_archive']);

  return ArchiveInventory({
    for (final entry in files.entries) entry.key: _fileIdentity(entry.value),
  });
}

ArchiveFileIdentity _fileIdentity(Object? value) {
  final record = _object(value);
  _require(
    record.length == 3 &&
        record['size'] is int &&
        record['mode'] is int &&
        record['sha256'] is String,
    'Invalid transport file identity',
  );
  return (
    size: record['size'] as int,
    mode: record['mode'] as int,
    sha256: record['sha256'] as String,
  );
}

Future<void> readPubTransport(
  File archive,
  Map<String, Object?> record,
  Directory source,
  Directory output,
  String commit,
  String run,
  String attempt, {
  bool registryReady = false,
}) async {
  final files = admitPubTransportRecord(
    record,
    commit,
    run,
    attempt,
    registryReady,
  );
  final pin = _object(record['archive']);
  _require(
    p.basename(archive.path) == 'installation.tar',
    'Unexpected transport archive filename',
  );
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Transport output already exists',
  );
  await withArchiveInput(archive, (input) async {
    final identity = await _source(source, commit);
    _require(
      sameJson(identity, record['source']),
      'Transport source differs from actual checkout',
    );
    await output.parent.create(recursive: true);
    await withTarExtraction(input, files, (extracted) async {
      late PubStageIdentity stage;
      if (registryReady) {
        await withPubCandidate(extracted, source, identity, (
          materialized,
          report,
        ) async {
          _require(
            sameJson(report['upload_archive'], record['upload_archive']),
            'Transport SDK upload differs from caller',
          );
          stage = await readPubStageReceipt(
            extracted,
            identity,
            registryReady: true,
          );
          await Directory(p.join(materialized.path, 'package'))
              .rename(p.join(extracted.path, 'package'));
        });
      } else {
        stage = await inspectPubStage(
          extracted,
          identity,
          registryReady: false,
        );
      }
      _require(
        stage.sha256 == record['stage_sha256'],
        'Transport stage receipt differs from caller pin',
      );
      _require(
        sameJson(await _source(source, commit), identity),
        'Transport source changed during inspection',
      );
    }, publishTo: output);
  }, expected: (size: pin['size'] as int, sha256: pin['sha256'] as String));
}

Future<Map<String, Object?>> writePubTransport(
  Directory stage,
  Directory source,
  Directory output,
  String commit,
  String run,
  String attempt, {
  bool registryReady = false,
}) async {
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Transport output already exists',
  );
  final identity = await _source(source, commit);
  Future<({PubStageIdentity stage, Map<String, Object?>? upload})>
  inspectBundle(Directory bundle) async {
    if (registryReady) {
      return withPubCandidate(
        bundle,
        source,
        identity,
        (_, report) async => (
          stage: await readPubStageReceipt(
            bundle,
            identity,
            registryReady: true,
          ),
          upload: _object(report['upload_archive']),
        ),
      );
    }
    return (
      stage: await inspectPubStage(bundle, identity, registryReady: false),
      upload: null,
    );
  }

  final checked = await inspectBundle(stage);

  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.archway-pub-transport-');
  var published = false;
  try {
    final artifact = Directory(p.join(temporary.path, 'artifact'));
    await exportInstallation(
      stage,
      artifact,
      registryReady
          ? pubCandidateFiles
          : {
              'pub-stage.json',
              for (final name in checked.stage.files.files.keys)
                'package/$name',
            },
      {'source': identity, 'run_id': run, 'run_attempt': attempt},
      (extracted, _) async {
        final observed = await inspectBundle(extracted);
        _require(
          observed.stage.sha256 == checked.stage.sha256 &&
              sameJson(observed.upload, checked.upload),
          'Stage changed during transport export',
        );
      },
    );
    final provenance = _object(
      decodeEvidenceJson(
        File(p.join(artifact.path, 'provenance.json')).readAsStringSync(),
      ),
    );
    final archive = File(p.join(artifact.path, 'installation.tar'));
    final record = <String, Object?>{
      'schema_version': registryReady ? 2 : 1,
      'source': identity,
      'run_id': run,
      'run_attempt': attempt,
      'registry_ready': registryReady,
      'stage_sha256': checked.stage.sha256,
      if (registryReady) 'upload_archive': checked.upload,
      'files': provenance['files'],
      'archive': {
        'size': archive.lengthSync(),
        'sha256': _object(provenance['archive'])['sha256'],
      },
    };
    final roundTrip = Directory(p.join(temporary.path, 'round-trip'));
    await readPubTransport(
      archive,
      record,
      source,
      roundTrip,
      commit,
      run,
      attempt,
      registryReady: registryReady,
    );
    await roundTrip.delete(recursive: true);
    await archive.rename(p.join(temporary.path, 'installation.tar'));
    await artifact.delete(recursive: true);
    File(p.join(temporary.path, 'transport.json'))
        .writeAsStringSync('${jsonEncode(record)}\n');
    publishDirectory(temporary, output);
    published = true;
    return record;
  } finally {
    if (!published) await temporary.delete(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser();
    for (final operation in ['write', 'read']) {
      final command = ArgParser()..addFlag('registry-ready', negatable: false);
      for (final name in [
        'source',
        'output',
        'expected-source',
        'run-id',
        'run-attempt',
        if (operation == 'write')
          'stage-evidence'
        else ...[
          'archive',
          'expected-json',
        ],
      ]) {
        command.addOption(name, mandatory: true);
      }
      parser.addCommand(operation, command);
    }
    final args = parser.parse(arguments).command;
    _require(
      args != null && args.rest.isEmpty,
      'Expected transport write or read command',
    );
    final source = Directory(args!['source'] as String).absolute;
    final output = Directory(args['output'] as String).absolute;
    final commit = args['expected-source'] as String,
        run = args['run-id'] as String,
        attempt = args['run-attempt'] as String;
    final registry = args['registry-ready'] as bool;
    Map<String, Object?> record;
    if (args.name == 'write') {
      record = await writePubTransport(
        Directory(args['stage-evidence'] as String).absolute,
        source,
        output,
        commit,
        run,
        attempt,
        registryReady: registry,
      );
    } else {
      final text = args['expected-json'] as String;
      _require(
        utf8.encode(text).length <= maxArchiveJsonBytes,
        'Expected transport record exceeds bound',
      );
      record = _object(decodeEvidenceJson(text));
      await readPubTransport(
        File(args['archive'] as String).absolute,
        record,
        source,
        output,
        commit,
        run,
        attempt,
        registryReady: registry,
      );
    }
    stdout.writeln(jsonEncode(record));
  } catch (error) {
    stderr.writeln('Pub stage transport failed: $error');
    exitCode = 1;
  }
}
