// Aggregate independently produced native and thin-wrapper release artifacts.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../npm/installed_identity.dart';
import '../npm/packed_candidate.dart';
import '../npm/stage.dart';
import '../release/archive_input.dart';
import '../release/native_payload.dart';
import 'release_execution_receipts.dart';
import 'release_final_assembly.dart';
import 'release_installed_admission.dart';
import 'release_native_admission.dart';
import 'release_native_input.dart';
import 'release_pub_input.dart';
import 'release_receipt_values.dart';

Future<void> finalizeNativeFirstRelease({
  required Directory native,
  required File descriptor,
  required Directory npmPacked,
  required Directory pubTransport,
  required Directory reports,
  required Directory installedEvidence,
  required Directory output,
  required Directory repository,
  required String expectedCommit,
  required String runId,
  required String runAttempt,
  required String expectedTransportJson,
  required bool registryReady,
}) async {
  requireReceipt(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Final output already exists',
  );
  await withNativeReleaseInput(
    source: repository,
    native: native,
    descriptor: descriptor,
    expectedCommit: expectedCommit,
    inspect: (input) async {
      final temporary = await Directory.systemTemp.createTemp(
        'archway-final-wrappers-',
      );
      try {
        final npmStage = Directory(p.join(temporary.path, 'npm'));
        await stageNpm(
          repository,
          input.descriptorFile,
          npmStage,
          expectedCommit,
          registryReady: registryReady,
        );
        final npmReceipt = await verifyNpmPackedCandidate(
          npmStage,
          npmPacked,
          expectedCommit: expectedCommit,
          registryReady: registryReady,
        );
        requireReceipt(
          exactReceipt(npmReceipt['source'], input.source) &&
              npmReceipt['version'] == input.version &&
              npmReceipt['descriptor_sha256'] == input.descriptorSha256,
          'Packed npm identity differs from independent native producer',
        );
        await withPubReleaseInput(
          source: repository,
          identity: input.source,
          descriptor: input.descriptorFile,
          transport: pubTransport,
          expectedTransportJson: expectedTransportJson,
          runId: runId,
          runAttempt: runAttempt,
          registryReady: registryReady,
          inspect: (pub) async {
            admitThinInstalledReceipts(
              root: installedEvidence,
              repository: repository,
              source: input.source,
              version: input.version,
              descriptor: input.descriptor,
              descriptorSha256: input.descriptorSha256,
              npmSha256: npmReceipt['sha256'] as String,
              wrapperEntrySha256: pub.wrapperEntrySha256,
              runId: runId,
              runAttempt: runAttempt,
              expectedTransportJson: expectedTransportJson,
              registryReady: registryReady,
              acquisitionMode: 'ci-verified-native',
            );
            final nativeReceipts = <String, AdmittedNativeReceipt>{};
            final reportDirectories = reports.listSync(followLinks: false);
            requireReceipt(
              reportDirectories.length == 3 &&
                  reportDirectories.every(
                    (entry) =>
                        entry is Directory &&
                        nativeTargets.containsKey(p.basename(entry.path)),
                  ),
              'Native report target inventory differs',
            );
            for (final target in nativeTargets.keys) {
              final name =
                  'archway-${input.version}-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
              final artifact = Directory(p.join(reports.path, target));
              nativeReceipts[target] = await admitNativeReceipt(
                report: oneReceiptFile(artifact, 'report.json'),
                artifact: artifact,
                archive: input.assets[name]!,
                target: target,
                version: input.version,
                archiveSha256: input.sums[name]!,
                source: input.source,
                repository: repository,
              );
            }
            // Keep the admitted npm bytes in the owning snapshot through publication.
            await withNpmPackedCandidate(
              npmPacked,
              expectedCommit: expectedCommit,
              registryReady: registryReady,
              inspect: (archive, receipt) async {
                requireReceipt(
                  exactReceipt(receipt, npmReceipt),
                  'Packed npm changed during finalization',
                );
                final assets = {
                  ...input.assets,
                  receipt['filename'] as String: archive,
                };
                final sums = {
                  ...input.sums,
                  receipt['filename'] as String: receipt['sha256'] as String,
                };
                final guide = File(
                  p.join(repository.path, 'tool/release/QUICKSTART.txt'),
                );
                final guideBytes = readOrdinaryBytes(
                  guide,
                  limit: maxArchiveJsonBytes,
                );
                assets['QUICKSTART.txt'] = guide;
                sums['QUICKSTART.txt'] = sha256.convert(guideBytes).toString();
                if (pub.upload != null) {
                  final name = 'archway-${input.version}-pub.tar.gz';
                  assets[name] = pub.upload!;
                  sums[name] =
                      receiptObject(pub.transport['upload_archive'])['sha256']
                          as String;
                }
                final packaging = {
                  'schema_version': 2,
                  'version': input.version,
                  'source': input.source,
                  'registry_ready': registryReady,
                  'run_id': runId,
                  'run_attempt': runAttempt,
                  'acquisition_mode': 'ci-verified-native',
                  'public_cold_verified': false,
                  'descriptor_sha256': input.descriptorSha256,
                  'native_bundles': receiptObject(
                    decodeEvidenceJson(utf8.decode(input.packagingBytes)),
                  )['native_bundles'],
                  'npm_tarball': receipt,
                  'pub_transport': pub.transport,
                };
                final originals = <String, ({Uint8List bytes, int mode})>{
                  'release-packaging.json': (
                    bytes: Uint8List.fromList(
                      utf8.encode(
                        '${const JsonEncoder.withIndent('  ').convert(packaging)}\n',
                      ),
                    ),
                    mode: 0x1a4,
                  ),
                  'native-packaging.json': (
                    bytes: Uint8List.fromList(input.packagingBytes),
                    mode: 0x1a4,
                  ),
                };
                await assembleFinalRelease(
                  output: output,
                  reports: reports,
                  repository: repository,
                  source: input.source,
                  assets: assets,
                  sums: sums,
                  evidenceName: 'archway-${input.version}-evidence.zip',
                  originals: originals,
                  accepted: nativeReceipts,
                  installedEvidence: installedEvidence,
                  producerEvidence: {
                    'native-producer': Directory(
                      p.join(native.path, 'evidence'),
                    ),
                    'pub-producer': pub.stage,
                  },
                );
              },
            );
          },
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser()..addFlag('registry-ready', negatable: false);
    for (final name in [
      'source',
      'native-directory',
      'descriptor',
      'npm-packed',
      'pub-transport',
      'reports',
      'installed-evidence',
      'output',
      'expected-commit',
      'run-id',
      'run-attempt',
      'expected-pub-transport-json',
    ]) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    requireReceipt(
      args.rest.isEmpty,
      'Unexpected native-first finalizer arguments',
    );
    Directory directory(String name) =>
        Directory(args[name] as String).absolute;
    await finalizeNativeFirstRelease(
      repository: directory('source'),
      native: directory('native-directory'),
      descriptor: File(args['descriptor'] as String).absolute,
      npmPacked: directory('npm-packed'),
      pubTransport: directory('pub-transport'),
      reports: directory('reports'),
      installedEvidence: directory('installed-evidence'),
      output: directory('output'),
      expectedCommit: args['expected-commit'] as String,
      runId: args['run-id'] as String,
      runAttempt: args['run-attempt'] as String,
      expectedTransportJson: args['expected-pub-transport-json'] as String,
      registryReady: args['registry-ready'] as bool,
    );
  } catch (error) {
    stderr.writeln('Native-first release finalization refused: $error');
    exitCode = 1;
  }
}
