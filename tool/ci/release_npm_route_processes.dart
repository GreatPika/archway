// npm-specific runtime, corpus and unsupported-platform originals.
import 'dart:convert';

import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

void validateNpmRuntimeProcesses(
  List<InstalledProcessEvidence> processes, {
  required InstalledOutputValidator output,
  required List<String> prefix,
  required String project,
  required String nativeExecutable,
  required String wrongNode,
  required String target,
}) {
  requireReceipt(
    processes.length == 5,
    'npm runtime process inventory differs',
  );
  final identity = processes[0];
  requireReceipt(
    exactReceipt(identity.arguments, [
          wrongNode,
          '-p',
          'JSON.stringify([process.version,process.platform,process.arch])',
        ]) &&
        identity.exitCode == 0 &&
        identity.stderr.isEmpty &&
        exactReceipt(jsonDecode(utf8.decode(identity.stdout)), [
          'v24.19.0',
          {
            'linux-x64': 'linux',
            'macos-arm64': 'darwin',
            'windows-x64': 'win32',
          }[target],
          target == 'macos-arm64' ? 'arm64' : 'x64',
        ]),
    'Original wrong-Node identity differs',
  );
  for (final (index, command) in [
    (1, prefix),
    (3, [nativeExecutable]),
  ]) {
    final process = processes[index];
    requireReceipt(
      exactReceipt(process.arguments, [...command, '--root', project, 'check']),
      'Wrong/missing analysis Node argv differs',
    );
    final value = output.publicResult(
      process,
      command: 'check',
      code: 2,
      status: 'incomplete',
      error: 'NODE_UNAVAILABLE',
      analysisComplete: false,
    );
    requireReceipt(
      value['resolved_root'] == project,
      'Runtime-control root differs',
    );
  }
  final launcher = processes[2];
  requireReceipt(
    exactReceipt(launcher.arguments, [...prefix, '--help']) &&
        launcher.exitCode != 0 &&
        launcher.stdout.isEmpty &&
        utf8.decode(launcher.stderr).toLowerCase().contains('node'),
    'Missing launcher Node was not a separate original failure',
  );
  final validate = processes[4];
  requireReceipt(
    exactReceipt(validate.arguments, [
      nativeExecutable,
      '--root',
      project,
      'validate',
    ]),
    'Native no-Node validate argv differs',
  );
  final value = output.publicResult(
    validate,
    command: 'validate',
    code: 0,
    status: 'ok',
  );
  requireReceipt(
    value['resolved_root'] == project,
    'Native no-Node validate root differs',
  );
}

void validateNpmCorpusProcesses(
  List<InstalledProcessEvidence> processes, {
  required InstalledOutputValidator output,
  required List<String> prefix,
  required String project,
  required String route,
}) {
  if (route != 'local') {
    requireReceipt(
      processes.isEmpty,
      'Out-of-root installation has corpus captures',
    );
    return;
  }
  requireReceipt(
    processes.length == 2,
    'npm corpus selection process inventory differs',
  );
  for (var index = 0; index < 2; index++) {
    final process = processes[index], excluded = index == 1;
    requireReceipt(
      exactReceipt(process.arguments, [...prefix, '--root', project, 'check']),
      'npm corpus argv differs',
    );
    final value = output.publicResult(
      process,
      command: 'check',
      code: excluded ? 0 : 2,
      status: excluded ? 'ok' : 'incomplete',
      analysisComplete: excluded,
    );
    final payload = receiptObject(value['payload']);
    final files = receiptList(receiptObject(payload['coverage'])['files'])
        .map((entry) => receiptObject(entry)['path']);
    requireReceipt(
      value['resolved_root'] == project &&
          files.contains(
                'node_modules/archway-architecture-cli/bin/archway.cjs',
              ) ==
              !excluded &&
          receiptObject(payload['observed'])['files'] == (excluded ? 2 : 3),
      'npm corpus source selection differs',
    );
  }
}

void validateNpmUnsupportedProcess(
  List<InstalledProcessEvidence> processes, {
  required String node,
  required String launcher,
}) {
  requireReceipt(
    processes.length == 1,
    'npm unsupported-target process inventory differs',
  );
  final process = processes.single;
  requireReceipt(
    exactReceipt(process.arguments, [
          node,
          '-e',
          "Object.defineProperty(process,'platform',{value:'freebsd'});require(process.argv[1]);",
          launcher,
        ]) &&
        process.exitCode == 126 &&
        process.stdout.isEmpty &&
        utf8
            .decode(process.stderr)
            .startsWith('archway launcher: unsupported target freebsd/'),
    'npm unsupported-target original selection differs',
  );
}
