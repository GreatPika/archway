// Admit private thin pub identity and every original SDK/core observation.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';
import 'release_installed_control_processes.dart';
import 'release_installed_control_receipts.dart';
import 'release_installed_core_processes.dart';
import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_pub_control_processes.dart';
import 'release_pub_thin_identity.dart';
import 'release_pub_sdk_receipts.dart';
import 'release_receipt_values.dart';

void validatePubThinReceipt(
  Map<String, dynamic> proof,
  Directory artifact, {
  required Directory repository,
  required Map<String, Object?> source,
  required String version,
  required String target,
  required Map<String, Object?> descriptor,
  required String descriptorSha256,
  required Map<String, Object?> transport,
  required String wrapperEntrySha256,
  required String runId,
  required String runAttempt,
  required bool registryReady,
  required String acquisitionMode,
}) {
  validatePubThinIdentity(
    proof,
    artifact,
    source: source,
    version: version,
    target: target,
    descriptor: descriptor,
    descriptorSha256: descriptorSha256,
    transport: transport,
    wrapperEntrySha256: wrapperEntrySha256,
    runId: runId,
    runAttempt: runAttempt,
    registryReady: registryReady,
    acquisitionMode: acquisitionMode,
  );
  validateInstalledCoreReceipts(proof['checks']);
  validateInstalledAssetReceipts(proof['asset_checks']);
  validateInstalledCommandReceipts(proof['command_checks']);
  requireReceipt(
    exactReceipt(proof['bridge_init'], {
      'case': 'missing-bridge-init',
      'invocation': 'installed-route',
      'exit': 2,
      'error': 'INIT_UNAVAILABLE',
    }),
    'Pub missing-bridge init summary differs',
  );
  final activation = validateInstalledProcessReceipts(
    proof['activation'],
    Directory(p.join(artifact.path, 'activation')),
    timeoutSeconds: {180},
  );
  requireReceipt(
    activation.length == 1 && activation.single.exitCode == 0,
    'Pub activation inventory or status differs',
  );
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final dart = activation.single.arguments.first;
  requireReceipt(
    paths.isAbsolute(dart) &&
        paths.basename(dart) ==
            (target == 'windows-x64' ? 'dart.exe' : 'dart') &&
        exactReceipt(activation.single.arguments, [
          dart,
          '--suppress-analytics',
          'pub',
          'global',
          'activate',
          '--no-executables',
          'archway',
          version,
        ]),
    'Pub activation must use the exact SDK command without aliases',
  );
  validatePubSdkReceipt(artifact, source: source, target: target, dart: dart);
  final prefix = [
    dart,
    '--suppress-analytics',
    'pub',
    'global',
    'run',
    'archway:archway',
  ];
  if (registryReady) {
    requireReceipt(
      exactReceipt(proof['private_export'], []),
      'Registry candidate cannot substitute private SDK export',
    );
  } else {
    final exported = validateInstalledProcessReceipts(
      proof['private_export'],
      Directory(p.join(artifact.path, 'private-export')),
      timeoutSeconds: {180},
    );
    requireReceipt(
      exported.length == 1 &&
          exported.single.exitCode == 0 &&
          exported.single.arguments.length == 7,
      'Private SDK export inventory differs',
    );
    final archive = exported.single.arguments[5];
    requireReceipt(
      paths.isAbsolute(archive) &&
          paths.basename(archive) == 'private-upload.tar.gz' &&
          exactReceipt(exported.single.arguments, [
            dart,
            '--suppress-analytics',
            'pub',
            'publish',
            '--to-archive',
            archive,
            '--skip-validation',
          ]),
      'Private SDK export command differs',
    );
  }
  final commands = validateInstalledProcessReceipts(
    proof['commands'],
    Directory(p.join(artifact.path, 'execution')),
    timeoutSeconds: {30},
  );
  final runtime = receiptObject(
    readRecord(oneReceiptFile(artifact, 'runtime.json')),
  );
  validatePubThinProcesses(
    commands,
    repository: repository,
    version: version,
    target: target,
    prefix: prefix,
    nativeExecutable: proof['native_executable'] as String,
    wrongNodeExecutable: runtime['executable'] as String,
    snapshotCases: receiptObject(proof['snapshots'])['cases'],
  );
}

/// Semantic composition follows original-file admission, never replaces it.
void validatePubThinProcesses(
  List<InstalledProcessEvidence> commands, {
  required Directory repository,
  required String version,
  required String target,
  required List<String> prefix,
  required String nativeExecutable,
  required String wrongNodeExecutable,
  required Object? snapshotCases,
}) {
  requireReceipt(
    commands.length == 42 && commands[5].arguments.length == prefix.length + 3,
    'Pub complete installed process inventory differs',
  );
  final project = commands[5].arguments[prefix.length + 1];
  validateInstalledCoreProcesses(
    commands.sublist(0, 10),
    repository: repository,
    version: version,
    prefix: prefix,
    project: project,
    target: target,
  );
  final output = InstalledOutputValidator(repository, version);
  validateInstalledCommandProcesses(
    commands.sublist(10, 21),
    output: output,
    prefix: prefix,
    project: project,
    nativeExecutable: nativeExecutable,
  );
  validateInstalledAssetProcesses(
    commands.sublist(22, 34),
    output: output,
    prefix: prefix,
    project: project,
    launcherErrorPrefix: 'archway pub launcher:',
  );
  validatePubControlProcesses(
    bridgeInit: commands[21],
    runtimes: commands.sublist(34, 38),
    snapshots: commands.sublist(38, 42),
    output: output,
    prefix: prefix,
    project: project,
    target: target,
    wrongNodeExecutable: wrongNodeExecutable,
    snapshotCases: snapshotCases,
  );
  requireReceipt(
    exactReceipt(commands[0].stdout, commands[38].stdout) &&
        exactReceipt(commands[0].stderr, commands[38].stderr),
    'Pub restored snapshot baseline differs from initial installed help',
  );
}
