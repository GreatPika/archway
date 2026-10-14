// One stage inventory admission shared by packing and final evidence inspection.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/gzip_input.dart';
import '../release/native_payload.dart';
import '../release/tar_input.dart';
import '../validation/json_values.dart';

typedef NpmStageAdmission = ({
  Map<String, Object?> receipt,
  ArchiveInventory inventory,
  Directory package,
  String inventorySha256,
});

void _require(bool value, String message) {
  if (!value) throw FormatException(message);
}

Future<NpmStageAdmission> admitNpmStage(Directory stage) async {
  stage = stage.absolute;
  _require(
    stage.resolveSymbolicLinksSync() == stage.path,
    'Expected canonical npm stage',
  );
  final receipt = await readNativeJson(
    File(p.join(stage.path, 'npm-stage.json')),
  );
  final rows = receipt['files'];
  _require(
    receipt['schema_version'] == 1 &&
        receipt['version'] is String &&
        receipt['source'] is Map &&
        receipt['descriptor_sha256'] is String &&
        receipt['registry_ready'] is bool &&
        rows is Map,
    'Invalid npm stage receipt',
  );
  final expected = <String, ArchiveFileIdentity>{};
  for (final entry in (rows as Map).entries) {
    final record = entry.value;
    _require(
      entry.key is String &&
          record is Map &&
          record.length == 3 &&
          record['size'] is int &&
          record['mode'] is int &&
          record['sha256'] is String,
      'Invalid npm stage file identity',
    );
    expected['package/${entry.key}'] = (
      size: record['size'] as int,
      mode: record['mode'] as int,
      sha256: record['sha256'] as String,
    );
  }
  final inventory = ArchiveInventory(expected);
  final package = Directory(p.join(stage.path, 'package'));
  _require(
    package.resolveSymbolicLinksSync() == package.path,
    'Aliased npm stage package',
  );
  final observed = <String>{};
  for (final entity in package.listSync(recursive: true, followLinks: false)) {
    _require(
      entity is File || entity is Directory,
      'Nonordinary npm stage entry',
    );
    _require(
      entity.resolveSymbolicLinksSync() == entity.path,
      'Aliased npm stage entry',
    );
    if (entity is File) {
      final name =
          'package/${p.relative(entity.path, from: package.path).replaceAll('\\', '/')}';
      final record = expected[name];
      _require(record != null, 'Unowned npm stage file: $name');
      await withArchiveInput(
        entity,
        (_) async {},
        expected: (size: record!.size, sha256: record.sha256),
      );
      observed.add(name);
    }
  }
  _require(observed.length == expected.length, 'Missing npm stage files');
  final descriptor = await readNativeJson(
    File(p.join(package.path, 'acquisition.json')),
  );
  final metadata = await readNativeJson(
    File(p.join(package.path, 'package.json')),
  );
  _require(
    expected['package/acquisition.json']?.sha256 ==
            receipt['descriptor_sha256'] &&
        descriptor['version'] == receipt['version'] &&
        sameJson(descriptor['source'], receipt['source']) &&
        metadata['name'] == 'archway-architecture-cli' &&
        metadata['version'] == receipt['version'] &&
        metadata['private'] == !(receipt['registry_ready'] as bool) &&
        sameJson(metadata['bin'], {'archway': 'bin/archway.cjs'}),
    'Npm stage identity differs',
  );
  return (
    receipt: receipt,
    inventory: inventory,
    package: package,
    inventorySha256: sha256.convert(utf8.encode(jsonEncode(rows))).toString(),
  );
}

Future<void> verifyNpmArchiveInput(
  ArchiveInput input,
  ArchiveInventory inventory,
) => withGzipSnapshot(
  input,
  (expanded) => withArchiveInput(expanded, (tar) async {
    try {
      await verifyTarInput(tar, inventory);
    } on FormatException catch (error, stack) {
      const bin = 'package/bin/archway.cjs';
      final executable = inventory.files[bin];
      if (executable == null || executable.mode != 0x1ed) rethrow;
      // npm's Windows pack can retain 0644 for a nested declared bin.
      // npm bin-links makes that bin executable during normal installation.
      // Keep canonical source identity and every other member exact: this is
      // a second complete inventory, never a general permission relaxation.
      final portable = ArchiveInventory({
        ...inventory.files,
        bin: (size: executable.size, mode: 0x1a4, sha256: executable.sha256),
      });
      try {
        await verifyTarInput(tar, portable);
      } on FormatException {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }),
);
