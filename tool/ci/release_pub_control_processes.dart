// Original pub-only runtime, bridge-init and SDK snapshot observations.
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';
import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

void validatePubControlProcesses({
  required InstalledProcessEvidence bridgeInit,
  required List<InstalledProcessEvidence> runtimes,
  required List<InstalledProcessEvidence> snapshots,
  required InstalledOutputValidator output,
  required List<String> prefix,
  required String project,
  required String target,
  required String wrongNodeExecutable,
  required Object? snapshotCases,
}) {
  const hosts = {
    'linux-x64': ('linux', 'x64'),
    'macos-arm64': ('darwin', 'arm64'),
    'windows-x64': ('win32', 'x64'),
  };
  requireReceipt(
    hosts.containsKey(target) &&
        prefix.isNotEmpty &&
        runtimes.length == 4 &&
        snapshots.length == 4 &&
        bridgeInit.arguments.length == prefix.length + 5,
    'Pub control process inventory differs',
  );
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final init = bridgeInit.arguments[prefix.length + 1];
  requireReceipt(
    paths.isAbsolute(init) &&
        sameEvidencePath(paths.dirname(init), paths.dirname(project), paths) &&
        paths.basename(init).startsWith('missing bridge init café-') &&
        exactReceipt(bridgeInit.arguments, [
          ...prefix,
          '--root',
          init,
          'init',
          '--template',
          'mixed',
        ]),
    'Pub unavailable init command differs',
  );
  final initialized = output.publicResult(
    bridgeInit,
    command: 'init',
    code: 2,
    status: 'error',
    error: 'INIT_UNAVAILABLE',
  );
  requireReceipt(
    initialized['resolved_root'] == init && initialized['payload'] == null,
    'Pub unavailable init root or payload differs',
  );
  final version = runtimes.first;
  requireReceipt(
    exactReceipt(version.arguments, [
          wrongNodeExecutable,
          '-p',
          'JSON.stringify([process.version,process.platform,process.arch])',
        ]) &&
        version.exitCode == 0 &&
        version.stderr.isEmpty &&
        exactReceipt(decodeEvidenceJson(utf8.decode(version.stdout)), [
          'v24.19.0',
          hosts[target]!.$1,
          hosts[target]!.$2,
        ]),
    'Pub wrong-Node original identity differs',
  );
  for (final process in runtimes.skip(1).take(2)) {
    requireReceipt(
      exactReceipt(process.arguments, [...prefix, '--root', project, 'check']),
      'Pub unavailable Node must use the installed SDK route',
    );
    final checked = output.publicResult(
      process,
      command: 'check',
      code: 2,
      status: 'incomplete',
      error: 'NODE_UNAVAILABLE',
      analysisComplete: false,
    );
    requireReceipt(
      checked['resolved_root'] == project,
      'Pub unavailable Node result root differs',
    );
  }
  final noNode = runtimes.last;
  requireReceipt(
    exactReceipt(noNode.arguments, [...prefix, '--root', project, 'validate']),
    'Pub no-Node validation must use the installed SDK route',
  );
  requireReceipt(
    output.publicResult(
          noNode,
          command: 'validate',
          code: 0,
          status: 'ok',
        )['resolved_root'] ==
        project,
    'Pub no-Node validation root differs',
  );
  for (final process in snapshots) {
    requireReceipt(
      exactReceipt(process.arguments, [...prefix, '--help']),
      'Pub snapshot must use the installed SDK route',
    );
  }
  final baseline = snapshots[0],
      poisoned = snapshots[1],
      stale = snapshots[2],
      missing = snapshots[3];
  requireReceipt(
    baseline.exitCode == 0 &&
        baseline.stderr.isEmpty &&
        utf8.decode(baseline.stdout).contains('--root') &&
        poisoned.exitCode == 0 &&
        exactReceipt(poisoned.stdout, baseline.stdout) &&
        exactReceipt(poisoned.stderr, baseline.stderr),
    'Pub poisoned-source snapshot changed original output',
  );
  requireReceipt(
    stale.exitCode != 0 &&
        stale.stderr.isNotEmpty &&
        !exactReceipt(stale.stdout, baseline.stdout) &&
        missing.exitCode != 0 &&
        utf8.decode(missing.stderr).contains('Error') &&
        !exactReceipt(missing.stdout, baseline.stdout) &&
        exactReceipt(snapshotCases, [
          {'case': 'poisoned-source-snapshot', 'exit': poisoned.exitCode},
          {'case': 'stale-snapshot', 'exit': stale.exitCode},
          {'case': 'missing-snapshot', 'exit': missing.exitCode},
        ]),
    'Pub stale/missing snapshot original failures differ',
  );
}
