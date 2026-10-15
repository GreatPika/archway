// Append matching original host receipts without rebuilding tested payloads.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/native_payload.dart' show nativePubspec;
import '../release/zip_input.dart';
import 'release_execution_receipts.dart';
import 'release_final_assembly.dart';
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
  final version = (await nativePubspec(repository))['version'] as String;
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
      version: version,
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
  await assembleFinalRelease(
    output: output,
    reports: reports,
    repository: repository,
    source: source,
    assets: {
      for (final name in expected)
        if (name != _evidenceName) name: File(p.join(release.path, name)),
    },
    sums: sums,
    evidenceName: _evidenceName,
    originals: originals,
    accepted: accepted,
    installedEvidence: installedEvidence,
  );
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
