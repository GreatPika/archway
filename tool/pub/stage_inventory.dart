// One complete thin-stage inventory, shared by export and transport consumers.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../release/archive_input.dart';
import '../release/installation_artifact.dart';
import '../release/strict_json.dart';
import '../validation/json_values.dart';
import 'stage.dart';

typedef PubStageIdentity = ({
  Map<String, Object?> receipt,
  ArchiveInventory files,
  String sha256,
});

void _require(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

/// Parses claimed stage identities; does not verify physical package bytes.
Future<PubStageIdentity> readPubStageReceipt(
  Directory stage,
  Map<String, Object?> source, {
  required bool registryReady,
}) async {
  final record = await withArchiveInput(
    File(p.join(stage.path, 'pub-stage.json')),
    (input) async => (
      value: decodeEvidenceJson(await input.file.readAsString()),
      sha256: input.sha256,
    ),
    maxBytes: maxArchiveJsonBytes,
  );
  final value = record.value;
  _require(
    value is Map<String, Object?> &&
        value.length == 6 &&
        value['schema_version'] is int &&
        value['schema_version'] == 1 &&
        sameJson(value['source'], source) &&
        value['registry_ready'] == registryReady &&
        value['version'] is String &&
        value['descriptor_sha256'] is String &&
        RegExp(r'^[0-9a-f]{64}$')
            .hasMatch(value['descriptor_sha256'] as String),
    'Pub stage receipt identity or intent differs',
  );
  final receipt = value as Map<String, Object?>;
  final listed = receipt['files'];
  final expectedNames = {
    ...pubStageSourceFiles,
    'bin/archway.dart',
    'pubspec.yaml',
    'README.md',
  };
  _require(
    listed is Map &&
        listed.length == expectedNames.length &&
        expectedNames.every(listed.containsKey),
    'Pub stage file set differs',
  );
  final identities = <String, ArchiveFileIdentity>{};
  for (final name in expectedNames) {
    final entry = (listed as Map)[name];
    _require(
      entry is Map &&
          entry.length == 2 &&
          entry['size'] is int &&
          entry['sha256'] is String,
      'Invalid pub stage file identity',
    );
    identities[name] = (
      size: entry['size'] as int,
      mode: 420,
      sha256: entry['sha256'] as String,
    );
  }
  final files = ArchiveInventory(identities);
  return (receipt: receipt, files: files, sha256: record.sha256);
}

Future<PubStageIdentity> inspectPubStage(
  Directory stage,
  Map<String, Object?> source, {
  required bool registryReady,
}) async {
  final checked = await readPubStageReceipt(
    stage,
    source,
    registryReady: registryReady,
  );
  final receipt = checked.receipt, files = checked.files;
  final package = Directory(p.join(stage.path, 'package'));
  await verifyInstallationDirectory(package, files, compareModes: false);
  final metadata = await withArchiveInput(
    File(p.join(package.path, 'pubspec.yaml')),
    (input) async => loadYaml(await input.file.readAsString()),
    maxBytes: maxArchiveJsonBytes,
  );
  _require(
    metadata is YamlMap &&
        metadata['name'] == 'archway' &&
        metadata['version'] == receipt['version'] &&
        metadata['repository'] == 'https://github.com/GreatPika/archway' &&
        metadata['executables'] == null &&
        sameJson(jsonDecode(jsonEncode(metadata['environment'])), {
          'sdk': '>=3.13.3 <4.0.0',
        }) &&
        (registryReady
            ? !metadata.containsKey('publish_to')
            : metadata['publish_to'] == 'none') &&
        sameJson(
          jsonDecode(jsonEncode(metadata['dependencies'])),
          pubStageDependencies,
        ),
    'Pub stage package metadata differs',
  );
  return checked;
}
