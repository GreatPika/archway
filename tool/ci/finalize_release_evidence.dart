// Append matching original host receipts without rebuilding tested payloads.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import '../release/zip_input.dart';
import 'release_execution_receipts.dart';
import 'release_installed_admission.dart';
import 'release_native_admission.dart';
import 'release_receipt_values.dart';

const _targets = ['linux-x64', 'macos-arm64', 'windows-x64'];
const _evidenceName = 'archway-0.1.0-evidence.zip';
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<void> finalizeRelease({
  required Directory release,
  required Directory reports,
  required Directory output,
  required String expectedCommit,
  Directory? repository,
  Directory? installedEvidence,
  bool registryReady = false,
  String? runId,
  String? runAttempt,
  String? expectedTransportJson,
}) async {
  requireReceipt(
    !registryReady || installedEvidence != null,
    'Registry-ready finalization requires installed receipts',
  );
  repository = (repository ?? Directory.current).absolute;
  release = release.absolute;
  reports = reports.absolute;
  output = output.absolute;
  requireReceipt(!_exists(output.path), 'Final output already exists');
  final source = await sourceIdentity(repository);
  requireReceipt(
    source['commit'] == expectedCommit,
    'Source differs from expected commit',
  );
  final expected = {
    for (final target in _targets)
      'archway-0.1.0-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}',
    'archway-architecture-cli-0.1.0.tgz',
    'QUICKSTART.txt',
    _evidenceName,
  };
  final sums = <String, String>{};
  final text = utf8.decode(
    readOrdinaryBytes(
      File(p.join(release.path, 'SHA256SUMS')),
      limit: maxArchiveJsonBytes,
    ),
  );
  for (final line in const LineSplitter().convert(text)) {
    final fields = line.split('  ');
    requireReceipt(
      fields.length == 2 &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(fields[0]) &&
          expected.contains(fields[1]) &&
          !sums.containsKey(fields[1]),
      'Unexpected checksum entry',
    );
    final file = File(p.join(release.path, fields[1]));
    requireReceipt(
      _hash(readOrdinaryBytes(file, limit: maxArchiveBytes)) == fields[0],
      'Producer asset checksum differs',
    );
    sums[fields[1]] = fields[0];
  }
  requireReceipt(
    exactReceipt(sums.keys.toList()..sort(), expected.toList()..sort()) &&
        exactReceipt(
          release
              .listSync(followLinks: false)
              .map((e) => p.basename(e.path))
              .toList()
            ..sort(),
          [...expected, 'SHA256SUMS']..sort(),
        ),
    'Expected exactly seven producer release files',
  );
  if (installedEvidence != null) {
    requireReceipt(
      runId != null && runAttempt != null && expectedTransportJson != null,
      'Installed receipts require independently bound source/run/transport inputs',
    );
    admitInstalledReceipts(
      root: installedEvidence.absolute,
      source: source,
      npmSha256: sums['archway-architecture-cli-0.1.0.tgz']!,
      runId: runId!,
      runAttempt: runAttempt!,
      expectedTransportJson: expectedTransportJson!,
      registryReady: registryReady,
      repository: repository,
    );
  }
  final accepted = <String, AdmittedNativeReceipt>{};
  for (final target in _targets) {
    final name =
        'archway-0.1.0-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
    accepted[target] = await admitNativeReceipt(
      artifact: Directory(p.join(reports.path, target)),
      report: oneReceiptFile(
        Directory(p.join(reports.path, target)),
        'report.json',
      ),
      archive: File(p.join(release.path, name)),
      target: target,
      archiveSha256: sums[name]!,
      source: source,
      repository: repository,
    );
  }
  final evidenceFile = File(p.join(release.path, _evidenceName));
  final originals = await withArchiveInput(
    evidenceFile,
    readZipFiles,
    expected: (size: evidenceFile.lengthSync(), sha256: sums[_evidenceName]!),
  );
  requireReceipt(
    !originals.keys.any((name) => name.startsWith('native-smoke/')),
    'Duplicate or already-finalized evidence',
  );
  final packaging = originals['release-packaging.json'];
  requireReceipt(
    packaging != null && packaging.bytes.length <= maxArchiveJsonBytes,
    'Producer packaging evidence missing or oversized',
  );
  requireReceipt(
    exactReceipt(
      receiptObject(
        decodeEvidenceJson(utf8.decode(packaging!.bytes)),
      )['source'],
      source,
    ),
    'Producer evidence source differs',
  );
  output.parent.createSync(recursive: true);
  final stage = output.parent.createTempSync('.archway-final-');
  try {
    for (final name in [...expected, 'SHA256SUMS']) {
      File(p.join(release.path, name)).copySync(p.join(stage.path, name));
    }
    final archiveEntries = archive.Archive();
    final names = <String>{};
    final combined = <String, ArchiveFileIdentity>{};
    var combinedBytes = 0;
    void append(String name, List<int> bytes, [int mode = 0x1a4]) {
      requireReceipt(names.add(name), 'Duplicate finalized evidence member');
      combinedBytes += bytes.length;
      requireReceipt(
        combinedBytes <= maxArchiveBytes && names.length <= maxArchiveEntries,
        'Combined evidence exceeds byte or entry bound',
      );
      combined[name] = (size: bytes.length, mode: mode, sha256: _hash(bytes));
      archiveEntries.addFile(
        archive.ArchiveFile.bytes(name, bytes)..mode = 0x8000 | mode,
      );
    }

    for (final original in originals.entries)
      append(original.key, original.value.bytes, original.value.mode);
    void appendFiles(Directory directory, String prefix, {File? installer}) {
      final inventory = <String, ArchiveFileIdentity>{};
      var totalBytes = 0;
      final entries = directory.listSync(recursive: true, followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (entity is Directory) continue;
        if (installer != null && entity.path == installer.path) continue;
        if (installer != null &&
            [
              '.deb',
              '.pkg',
              '.exe',
            ].contains(p.extension(entity.path).toLowerCase())) {
          throw FormatException(
            'Unexpected installer binary in native evidence: ${p.basename(entity.path)}',
          );
        }
        final file = File(entity.path);
        final bytes = readOrdinaryBytes(file);
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
    ArchiveInventory(combined);
    File(p.join(stage.path, _evidenceName))
        .writeAsBytesSync(archive.ZipEncoder().encode(archiveEntries));
    for (final entry in sums.entries) {
      if (entry.key == _evidenceName) continue;
      requireReceipt(
        _hash(
              readOrdinaryBytes(
                File(p.join(stage.path, entry.key)),
                limit: maxArchiveBytes,
              ),
            ) ==
            entry.value,
        'Tested release payload changed during finalization',
      );
    }
    final payloads = [
      ...expected,
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

Future<void> main(List<String> arguments) async {
  final parser = ArgParser();
  for (final name in [
    'release-directory',
    'reports',
    'output',
    'expected-commit',
  ])
    parser.addOption(name, mandatory: true);
  for (final name in [
    'installed-evidence',
    'run-id',
    'run-attempt',
    'expected-pub-transport-json',
  ])
    parser.addOption(name);
  parser.addFlag('registry-ready', negatable: false);
  try {
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty)
      throw const FormatException('Unexpected finalizer arguments');
    await finalizeRelease(
      release: Directory(args['release-directory'] as String),
      reports: Directory(args['reports'] as String),
      output: Directory(args['output'] as String),
      expectedCommit: args['expected-commit'] as String,
      installedEvidence: args['installed-evidence'] == null
          ? null
          : Directory(args['installed-evidence'] as String),
      registryReady: args['registry-ready'] as bool,
      runId: args['run-id'] as String?,
      runAttempt: args['run-attempt'] as String?,
      expectedTransportJson: args['expected-pub-transport-json'] as String?,
    );
  } catch (error) {
    stderr.writeln('Release finalization refused: $error');
    exitCode = 1;
  }
}
