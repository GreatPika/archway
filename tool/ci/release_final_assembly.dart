// Assemble admitted release assets and original evidence without rebuilding them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import 'release_execution_receipts.dart';
import 'release_native_admission.dart';
import 'release_receipt_values.dart';

// Compose admitted route evidence under a separate output entry limit.
// Keep every per-input bound and the 512 MiB aggregate byte cap.
const maxFinalEvidenceEntries = 8192;

String _hash(List<int> bytes) => sha256.convert(bytes).toString();
bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<void> assembleFinalRelease({
  required Directory output,
  required Directory reports,
  required Directory repository,
  required Map<String, Object?> source,
  required Map<String, File> assets,
  required Map<String, String> sums,
  required String evidenceName,
  required Map<String, ({Uint8List bytes, int mode})> originals,
  required Map<String, AdmittedNativeReceipt> accepted,
  Directory? installedEvidence,
  Map<String, Directory> producerEvidence = const {},
}) async {
  requireReceipt(!_exists(output.path), 'Final output already exists');
  requireReceipt(
    !assets.containsKey(evidenceName) &&
        [
          ...assets.keys,
          evidenceName,
        ].every((name) => p.basename(name) == name && !name.contains('\\')),
    'Invalid final asset filename',
  );
  output.parent.createSync(recursive: true);
  final stage = output.parent.createTempSync('.archway-final-');
  try {
    for (final entry in assets.entries) {
      entry.value.copySync(p.join(stage.path, entry.key));
    }
    final archiveEntries = archive.Archive();
    final names = <String>{};
    var combinedBytes = 0;
    void append(String name, List<int> bytes, [int mode = 0x1a4]) {
      requireReceipt(names.add(name), 'Duplicate finalized evidence member');
      combinedBytes += bytes.length;
      requireReceipt(
        bytes.length <= maxArchiveFileBytes &&
            combinedBytes <= maxArchiveBytes &&
            names.length <= maxFinalEvidenceEntries,
        'Combined evidence exceeds byte or entry bound',
      );
      archiveEntries.addFile(
        archive.ArchiveFile.bytes(name, bytes)..mode = 0x8000 | mode,
      );
    }

    ArchiveInventory({
      for (final original in originals.entries)
        original.key: (
          size: original.value.bytes.length,
          mode: original.value.mode,
          sha256: _hash(original.value.bytes),
        ),
    });
    for (final original in originals.entries)
      append(original.key, original.value.bytes, original.value.mode);
    void appendFiles(
      Directory directory,
      String prefix, {
      File? installer,
      ({File file, ArchiveFileIdentity identity})? provenanceExecutable,
    }) {
      final inventory = <String, ArchiveFileIdentity>{};
      var totalBytes = 0;
      final entries = directory.listSync(recursive: true, followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (entity is Directory) continue;
        if (installer != null && entity.path == installer.path) continue;
        final file = File(entity.path);
        final bytes = readOrdinaryBytes(file);
        final admittedExecutable =
            provenanceExecutable != null &&
            entity.path == provenanceExecutable.file.path &&
            bytes.length == provenanceExecutable.identity.size &&
            _hash(bytes) == provenanceExecutable.identity.sha256;
        if (installer != null &&
            !admittedExecutable &&
            [
              '.deb',
              '.pkg',
              '.exe',
            ].contains(p.extension(entity.path).toLowerCase())) {
          throw FormatException(
            'Unexpected installer binary in native evidence: ${p.basename(entity.path)}',
          );
        }
        totalBytes += bytes.length;
        requireReceipt(
          totalBytes <= maxArchiveBytes && inventory.length < maxArchiveEntries,
          'Original evidence inventory exceeds bound',
        );
        final name = p
            .split(p.relative(file.path, from: directory.path))
            .join('/');
        inventory[name] = (
          size: bytes.length,
          mode: 0x1a4,
          sha256: _hash(bytes),
        );
        // Complete portable-name checks finish before the archive is encoded.
        append('$prefix/$name', bytes);
      }
      ArchiveInventory(inventory);
    }

    for (final entry in producerEvidence.entries) {
      appendFiles(entry.value, entry.key);
    }
    if (installedEvidence != null)
      appendFiles(installedEvidence.absolute, 'installed-routes');
    for (final entry in accepted.entries) {
      final installer = entry.value.installer;
      final destination = File(p.join(stage.path, p.basename(installer.path)));
      requireReceipt(
        !_exists(destination.path),
        'Installer name collides with producer payload',
      );
      installer.copySync(destination.path);
      requireReceipt(
        _hash(readOrdinaryBytes(destination, limit: maxArchiveBytes)) ==
            entry.value.installerSha256,
        'Tested installer changed during finalization',
      );
      append(
        'native-smoke/${entry.key}.json',
        readOrdinaryBytes(entry.value.report),
      );
      appendFiles(
        Directory(p.join(reports.path, entry.key)),
        'native-smoke/${entry.key}',
        installer: installer,
        provenanceExecutable: entry.value.provenanceExecutable,
      );
    }
    append(
      'native-smoke/acceptance.json',
      utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert({
          'source': source,
          'original_producer_sha256': sums,
          'scope': 'Matching three-host native archive receipts; payload archives unchanged',
          'workflow': {
            for (final name in ['GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT']) name: Platform.environment[name],
          },
        })}\n',
      ),
    );
    validatePortableArchiveNames(names);
    File(p.join(stage.path, evidenceName))
        .writeAsBytesSync(archive.ZipEncoder().encode(archiveEntries));
    for (final name in assets.keys) {
      final digest = sums[name];
      requireReceipt(
        _hash(
              readOrdinaryBytes(
                File(p.join(stage.path, name)),
                limit: maxArchiveBytes,
              ),
            ) ==
            digest,
        'Tested release payload changed during finalization',
      );
    }
    final payloads = [
      ...assets.keys,
      evidenceName,
      for (final receipt in accepted.values) p.basename(receipt.installer.path),
    ]..sort();
    File(p.join(stage.path, 'SHA256SUMS')).writeAsStringSync(
      payloads
          .map(
            (name) =>
                '${_hash(File(p.join(stage.path, name)).readAsBytesSync())}  $name\n',
          )
          .join(),
    );
    requireReceipt(
      exactReceipt(await sourceIdentity(repository), source),
      'Source changed during finalization',
    );
    publishDirectory(stage, output);
  } finally {
    if (stage.existsSync()) stage.deleteSync(recursive: true);
  }
}
