// Original argv and stream semantics for the shared destructive control owners.
import 'dart:convert';

import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

void validateInstalledAssetProcesses(
  List<InstalledProcessEvidence> processes, {
  required InstalledOutputValidator output,
  required List<String> prefix,
  required String project,
  required String launcherErrorPrefix,
}) {
  requireReceipt(
    processes.length == 12,
    'Installed asset process inventory differs',
  );
  const errors = [
    'TYPESCRIPT_ASSETS_UNAVAILABLE',
    'TYPESCRIPT_HELPER_FAILED',
    'TYPESCRIPT_ASSETS_UNAVAILABLE',
    'TYPESCRIPT_ASSETS_UNAVAILABLE',
    'TYPESCRIPT_LOAD_FAILED',
  ];
  for (var index = 0; index < errors.length; index++) {
    final process = processes[index];
    requireReceipt(
      exactReceipt(process.arguments, [...prefix, '--root', project, 'check']),
      'Installed asset argv differs',
    );
    final result = output.publicResult(
      process,
      command: 'check',
      code: 2,
      status: 'incomplete',
      error: errors[index],
      analysisComplete: false,
    );
    requireReceipt(
      result['resolved_root'] == project,
      'Installed asset root differs',
    );
  }
  for (final process in processes.skip(errors.length).take(6)) {
    requireReceipt(
      exactReceipt(process.arguments, [...prefix, '--help']) &&
          process.exitCode == 126 &&
          process.stdout.isEmpty &&
          utf8.decode(process.stderr).startsWith(launcherErrorPrefix),
      'Installed prelaunch refusal streams or argv differ',
    );
  }
  final restored = processes.last;
  requireReceipt(
    exactReceipt(restored.arguments, [...prefix, '--help']) &&
        restored.exitCode == 0 &&
        restored.stderr.isEmpty &&
        utf8.decode(restored.stdout).startsWith('archway [--root ROOT]'),
    'Installed restored help differs',
  );
}

void validateInstalledCommandProcesses(
  List<InstalledProcessEvidence> processes, {
  required InstalledOutputValidator output,
  required List<String> prefix,
  required String project,
  required String nativeExecutable,
}) {
  requireReceipt(
    processes.length == 11,
    'Installed command process inventory differs',
  );
  const operations = [
    ['validate'],
    ['node'],
    ['export', '--format', 'mermaid'],
    [r'unknown; $(touch should-not-exist) & café'],
  ];
  for (var index = 0; index < operations.length; index++) {
    final native = processes[index * 2], wrapped = processes[index * 2 + 1];
    final suffix = ['--root', project, ...operations[index]];
    requireReceipt(
      exactReceipt(native.arguments, [nativeExecutable, ...suffix]) &&
          exactReceipt(wrapped.arguments, [...prefix, ...suffix]) &&
          native.exitCode == (index == 3 ? 64 : 0) &&
          wrapped.exitCode == native.exitCode &&
          exactReceipt(native.stdout, wrapped.stdout) &&
          exactReceipt(native.stderr, wrapped.stderr),
      'Installed command original native parity differs',
    );
    if (index == 2) {
      output.exportResult(
        native,
        code: 0,
        status: 'ok',
        allowEmptySuccess: true,
      );
      requireReceipt(
        native.stdout.isNotEmpty,
        'Native Mermaid output is empty',
      );
    } else {
      final result = output.publicResult(
        native,
        command: index == 3 ? null : operations[index].first,
        code: index == 3 ? 64 : 0,
        status: index == 3 ? 'usage_error' : 'ok',
        error: index == 3 ? 'USAGE_ERROR' : null,
      );
      requireReceipt(
        result['resolved_root'] == (index == 3 ? null : project),
        'Native command root differs',
      );
    }
  }
  final validate = processes[8];
  requireReceipt(
    exactReceipt(validate.arguments, [
      ...prefix,
      '--root',
      project,
      'validate',
    ]),
    'Bridge-free validate argv differs',
  );
  final value = output.publicResult(
    validate,
    command: 'validate',
    code: 0,
    status: 'ok',
  );
  requireReceipt(
    value['resolved_root'] == project,
    'Bridge-free validate root differs',
  );
  final arguments = [
    ...prefix,
    '--root',
    project,
    'export',
    '--format',
    'mermaid',
    '--out',
    'bridge output café.mmd',
  ];
  final missing = processes[9], restored = processes[10];
  requireReceipt(
    exactReceipt(missing.arguments, arguments) &&
        exactReceipt(restored.arguments, arguments),
    'Bridge export argv differs',
  );
  final failed = output.exportResult(
    missing,
    code: 2,
    status: 'error',
    error: 'EXPORT_WRITE_FAILED',
    fileOutput: true,
  )!;
  requireReceipt(
    failed['resolved_root'] == project,
    'Missing-bridge export root differs',
  );
  output.exportResult(
    restored,
    code: 0,
    status: 'ok',
    fileOutput: true,
    allowEmptySuccess: true,
  );
  requireReceipt(
    restored.stderr.isEmpty,
    'Restored bridge export stderr differs',
  );
}
