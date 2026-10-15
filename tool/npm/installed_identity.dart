// Bind installed-route evidence to the packed candidate and selected native cache.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/native_manifest.dart';
import '../release/native_payload.dart';
import '../release/strict_json.dart';
import '../validation/json_values.dart';

void _require(bool value, String message) {
  if (!value) throw FormatException(message);
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _version(Object? value) =>
    value is String &&
    value.length <= 200 &&
    RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$').hasMatch(value);

Future<T> withNpmPackedCandidate<T>(
  Directory packed, {
  required String expectedCommit,
  required bool registryReady,
  String? legacyPackedReceiptSha256,
  required Future<T> Function(File archive, Map<String, Object?> receipt)
  inspect,
}) async {
  _require(
    packed.resolveSymbolicLinksSync() == packed.path,
    'Packed npm directory must be canonical',
  );
  _require(
    legacyPackedReceiptSha256 == null || _digest(legacyPackedReceiptSha256),
    'Invalid legacy npm packed receipt pin',
  );
  final receipt = await withArchiveInput(
    File(p.join(packed.path, 'npm-packed.json')),
    (input) async {
      _require(
        legacyPackedReceiptSha256 == null ||
            input.sha256 == legacyPackedReceiptSha256,
        'Legacy npm packed receipt pin differs',
      );
      // Hash and parse the same bounded owned snapshot, never reopen the input.
      return decodeEvidenceJson(await input.file.readAsString())
          as Map<String, Object?>;
    },
    maxBytes: maxArchiveJsonBytes,
  );
  final source = receipt['source'];
  final name = receipt['filename'];
  final size = receipt['compressed_bytes'];
  _require(
    receipt.length == 9 &&
        receipt['schema_version'] == 1 &&
        source is Map &&
        source['commit'] == expectedCommit &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(expectedCommit) &&
        _version(receipt['version']) &&
        receipt['registry_ready'] == registryReady &&
        _digest(receipt['descriptor_sha256']) &&
        _digest(receipt['stage_inventory_sha256']) &&
        _digest(receipt['sha256']) &&
        size is int &&
        size > 0 &&
        size <= maxArchiveBytes &&
        name is String &&
        name == 'archway-architecture-cli-${receipt['version']}.tgz' &&
        !name.contains('/') &&
        !name.contains('\\'),
    'Invalid packed npm identity',
  );
  final entries = packed.listSync(followLinks: false);
  _require(
    entries.length == 2 &&
        entries.every(
          (entry) =>
              entry is File &&
              [name, 'npm-packed.json'].contains(p.basename(entry.path)),
        ),
    'Unexpected packed npm input inventory',
  );
  return withArchiveInput(
    File(p.join(packed.path, name as String)),
    (snapshot) async => inspect(
      await snapshot.file.copy(p.join(snapshot.file.parent.path, name)),
      receipt,
    ),
    expected: (size: size as int, sha256: receipt['sha256'] as String),
  );
}

Future<Map<String, Object?>> readInstalledNpmDescriptor(
  Directory wrapper,
  Map<String, Object?> receipt,
) async {
  _require(_version(receipt['version']), 'Invalid native release version');
  final descriptor = await withArchiveInput(
    File(p.join(wrapper.path, 'acquisition.json')),
    (input) async {
      _require(
        input.sha256 == receipt['descriptor_sha256'],
        'Installed descriptor digest differs',
      );
      return decodeEvidenceJson(await input.file.readAsString())
          as Map<String, Object?>;
    },
    maxBytes: maxArchiveJsonBytes,
  );
  final metadata = await readNativeJson(
    File(p.join(wrapper.path, 'package.json')),
  );
  _require(
    descriptor['schema_version'] == 1 &&
        descriptor['version'] == receipt['version'] &&
        sameJson(descriptor['source'], receipt['source']) &&
        metadata['name'] == 'archway-architecture-cli' &&
        metadata['version'] == receipt['version'] &&
        metadata['private'] == !(receipt['registry_ready'] as bool),
    'Installed npm identity differs',
  );
  return descriptor;
}

Future<({Directory payload, Map<String, Object?> descriptor})>
inspectNpmNativeCache({
  required Directory wrapper,
  required Directory cache,
  required String target,
  required Map<String, Object?> receipt,
}) async {
  _require(nativeTargets.containsKey(target), 'Unsupported npm native target');
  final descriptor = await readInstalledNpmDescriptor(wrapper, receipt);
  final pin = (descriptor['targets'] as Map)[target] as Map;
  _require(
    _digest(pin['sha256']) && _digest(pin['manifest_sha256']),
    'Invalid selected native pin',
  );
  final parent = Directory(
    p.join(cache.path, descriptor['version'] as String, target),
  );
  final record = await withArchiveInput(
    File(p.join(parent.path, pin['sha256'] as String)),
    (input) => input.file.readAsString(),
    maxBytes: 64,
  );
  _require(
    RegExp(
      r'^\.archway-native-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n$',
    ).hasMatch(record),
    'Invalid native cache publication record',
  );
  final payload = Directory(
    p.join(parent.path, record.substring(0, record.length - 1)),
  );
  _require(
    payload.resolveSymbolicLinksSync() == payload.path,
    'Native cache payload is aliased',
  );
  final manifest = await readNativeManifest(
    File(p.join(payload.path, 'manifest.json')),
  );
  _require(
    manifest.manifestSha256 == pin['manifest_sha256'] &&
        manifest.manifest['schema_version'] == 1 &&
        manifest.manifest['target'] == target &&
        manifest.manifest['version'] == descriptor['version'] &&
        sameJson(manifest.manifest['source'], descriptor['source']),
    'Selected native manifest differs',
  );
  final relative = 'bin/$target/${nativeTargets[target]!.$1}';
  final executable = manifest.completeArchiveInventory.files[relative];
  _require(executable != null, 'Native executable identity is missing');
  await withArchiveInput(
    File(p.joinAll([payload.path, ...relative.split('/')])),
    (_) async {},
    expected: (size: executable!.size, sha256: executable.sha256),
    maxBytes: maxArchiveFileBytes,
  );
  return (payload: payload, descriptor: descriptor);
}
