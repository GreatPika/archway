// Admit one final native archive and all original host evidence before copying.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/native_archive.dart';
import '../validation/json_values.dart';
import 'release_execution_receipts.dart';
import 'release_installer_receipts.dart';
import 'release_native_acceptance_receipts.dart';
import 'release_source_receipts.dart';

/// Original paths and byte identities. Publication must recheck copied bytes.
final class AdmittedNativeReceipt {
  AdmittedNativeReceipt._(
    this.report,
    this.installer,
    this.installerSha256,
    this.provenanceExecutable,
  );
  // Only this retained smoke-test executable may resemble an installer filename.
  final ({File file, ArchiveFileIdentity identity})? provenanceExecutable;
  final File report;
  final File installer;
  final String installerSha256;
}

/// Source identity and producer checksums are independently supplied by finalization.
/// This boundary does not execute native payloads or claim native-host acceptance.
Future<AdmittedNativeReceipt> admitNativeReceipt({
  required File report,
  required Directory artifact,
  required File archive,
  required String target,
  required String version,
  required String archiveSha256,
  required Map<String, Object?> source,
  required Directory repository,
}) async {
  if (!['linux-x64', 'macos-arm64', 'windows-x64'].contains(target)) {
    throw const FormatException('Unsupported native receipt target');
  }
  final proof = readRecord(report);
  if (proof is! Map<String, dynamic>)
    throw const FormatException('Native receipt must be an object');
  final cases = proof['typescript'];
  if (cases is! List || cases.any((c) => c is! Map || c['exit'] is! int)) {
    throw const FormatException('Native TypeScript case inventory is invalid');
  }
  final filename =
      'archway-$version-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
  if (!sameJson(proof['source'], source) ||
      proof['target'] != target ||
      proof['ci_host_verified'] != true ||
      proof['archive'] != filename ||
      proof['archive_sha256'] != archiveSha256 ||
      !sameJson(proof['native_commands'], [
        'help',
        'version',
        'init',
        'validate',
        'export',
      ]) ||
      !sameJson(
        cases.map((c) => {'case': c['case'], 'exit': c['exit']}).toList(),
        [
          for (final entry in const {
            'clean': 0,
            'dependency-violation': 1,
            'unsupported-option': 64,
            'missing-owned-helper': 2,
            'restored-clean': 0,
          }.entries)
            {'case': entry.key, 'exit': entry.value},
        ],
      )) {
    throw const FormatException(
      'Native receipt does not establish required archive checks',
    );
  }
  final verified = await verifyNativeArchive(
    archive,
    format: target == 'windows-x64'
        ? NativeArchiveFormat.zip
        : NativeArchiveFormat.tarGzip,
  );
  if (verified.manifest['version'] != version) {
    throw const FormatException('Native archive version differs from source');
  }
  if (verified.archiveSha256 != archiveSha256) {
    throw const FormatException('Native archive checksum differs');
  }
  validateNative(proof, report, artifact, source);
  await validateSource(
    proof,
    report,
    Map<String, dynamic>.from(verified.manifest),
    repository,
  );
  final installer = validateInstaller(
    proof,
    report.parent,
    verified.manifestSha256,
    repository: repository,
    version: version,
  );
  final executable =
      verified.completeArchiveInventory.files['bin/windows-x64/archway.exe'];
  return AdmittedNativeReceipt._(
    report,
    installer,
    proof['installer']['artifact']['sha256'] as String,
    target == 'windows-x64' && executable != null
        ? (
            file: File(
              p.join(
                report.parent.path,
                'acceptance',
                'package-provenance',
                'installation',
                'bin',
                'windows-x64',
                'archway.exe',
              ),
            ),
            identity: executable,
          )
        : null,
  );
}
