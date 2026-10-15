// Same-source npm thin-route admission; private acquisition never earns public credit.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';
import 'release_installed_control_receipts.dart';
import 'release_installed_control_processes.dart';
import 'release_installed_core_processes.dart';
import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_npm_expanded_receipts.dart';
import 'release_npm_route_processes.dart';
import 'release_npm_setup_receipts.dart';
import 'release_npm_termination_evidence.dart';
import 'release_npm_termination_receipts.dart';
import 'release_receipt_values.dart';

void validateNpmThinReceipt(
  Map<String, dynamic> proof,
  Directory artifact, {
  required Map<String, Object?> source,
  required Map<String, Object?> descriptor,
  required String target,
  required String route,
  required String tarballSha256,
  required String descriptorSha256,
  required String runId,
  required String runAttempt,
  required bool registryReady,
  required String acquisitionMode,
  required Directory repository,
}) {
  requireReceipt(
    ['linux-x64', 'macos-arm64', 'windows-x64'].contains(target) &&
        ['local', 'global', 'cache'].contains(route) &&
        ['ci-verified-native', 'public-https-cold'].contains(acquisitionMode),
    'Unknown npm installed admission target/route/mode',
  );
  final pin = receiptObject(receiptObject(descriptor['targets'])[target]);
  requireReceipt(
    proof['schema_version'] is int &&
        proof['schema_version'] == 1 &&
        proof['status'] == 'passed' &&
        proof['ci_host_verified'] == true &&
        proof['target'] == target &&
        proof['route'] == route &&
        proof['registry_ready'] == registryReady &&
        proof['run_id'] == runId &&
        proof['run_attempt'] == runAttempt &&
        proof['source_commit'] == source['commit'] &&
        exactReceipt(proof['source'], source) &&
        exactReceipt(proof['native_source'], source) &&
        exactReceipt(descriptor['source'], source) &&
        proof['version'] == descriptor['version'] &&
        proof['tarball_sha256'] == tarballSha256 &&
        proof['descriptor_sha256'] == descriptorSha256 &&
        exactReceipt(proof['acquisition'], {
          'mode': acquisitionMode,
          'descriptor_sha256': descriptorSha256,
          'archive_sha256': pin['sha256'],
          'manifest_sha256': pin['manifest_sha256'],
          'public_cold_verified': acquisitionMode == 'public-https-cold',
        }),
    'npm source/run/candidate/acquisition identity differs',
  );
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  bool absolute(Object? value) =>
      value is String &&
      !value.contains('\u0000') &&
      paths.isAbsolute(value) &&
      paths.normalize(value) == value;
  requireReceipt(
    [
          'node_executable',
          'npm_cli',
          'archive_path',
        ].every((key) => absolute(proof[key])) &&
        paths.basename(proof['archive_path'] as String) ==
            'archway-architecture-cli-${descriptor['version']}.tgz' &&
        proof['process_directory'] == 'processes',
    'npm runtime/archive/evidence origin differs',
  );
  final directory = Directory(p.join(artifact.path, 'processes'));
  final processes = validateInstalledProcessReceipts(
    proof['processes'],
    directory,
    timeoutSeconds: {30, 120, 150},
    timeoutFor: (index, arguments) {
      if (index == 1) return 120; // Actual npm installation/cache selection.
      final private = acquisitionMode == 'ci-verified-native';
      if (index == (private ? 3 : 2) || private && index == 2) return 150;
      if (arguments.length == 3 &&
          arguments[1] == '-p' &&
          arguments[2] ==
              'JSON.stringify([process.version,process.platform,process.arch])') {
        return 30; // Explicit official wrong-Node identity capture.
      }
      return route == 'cache' ? 120 : 30;
    },
  );
  final phases = receiptList(proof['phases']);
  requireReceipt(
    exactReceipt(
      phases.map((phase) => receiptObject(phase)['phase']).toList(),
      route == 'cache' ? ['cached'] : ['installed', 'relocated'],
    ),
    'npm installed/relocated/cache phase inventory differs',
  );
  final output = InstalledOutputValidator(
    repository,
    descriptor['version'] as String,
  );
  final runtime = receiptObject(
    readRecord(oneReceiptFile(artifact, 'runtime.json')),
  );
  final terminationDirectories = <String>{};
  int? cursor;
  for (final value in phases) {
    final phase = receiptObject(value),
        ranges = receiptObject(phase['process_ranges']);
    requireReceipt(
      [
        'shim',
        'wrapper',
        'payload',
        'project',
        'cwd',
      ].every((key) => absolute(phase[key])),
      'npm phase paths are not canonical absolute origins',
    );
    final shim = phase['shim'] as String,
        wrapper = phase['wrapper'] as String,
        project = phase['project'] as String,
        payload = phase['payload'] as String;
    final prefix = List<String>.from(receiptList(phase['command_prefix']));
    requireReceipt(
      exactReceipt(
            prefix,
            route == 'cache'
                ? [
                    proof['node_executable'],
                    proof['npm_cli'],
                    'exec',
                    '--offline',
                    '--yes',
                    '--package=${proof['archive_path']}',
                    '--',
                    'archway',
                  ]
                : [shim],
          ) &&
          !paths.isWithin(wrapper, payload) &&
          !paths.isWithin(project, payload) &&
          paths.basename(paths.dirname(payload)) == target &&
          paths.basename(paths.dirname(paths.dirname(payload))) ==
              descriptor['version'] &&
          RegExp(
            r'^\.archway-native-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(paths.basename(payload)),
      'npm selected command/cache identity differs',
    );
    if (route == 'local') {
      requireReceipt(
        wrapper ==
                paths.join(
                  project,
                  'node_modules',
                  'archway-architecture-cli',
                ) &&
            shim ==
                paths.join(
                  project,
                  'node_modules',
                  '.bin',
                  target == 'windows-x64' ? 'archway.cmd' : 'archway',
                ),
        'npm local installation is outside the inspected project',
      );
    } else if (route == 'global') {
      final root = target == 'windows-x64'
          ? paths.dirname(shim)
          : paths.dirname(paths.dirname(shim));
      requireReceipt(
        wrapper ==
                paths.joinAll([
                  root,
                  if (target != 'windows-x64') 'lib',
                  'node_modules',
                  'archway-architecture-cli',
                ]) &&
            !paths.isWithin(project, wrapper),
        'npm global prefix layout differs',
      );
    } else {
      final selected = receiptObject(proof['cache_selection']);
      requireReceipt(
        selected['shim'] == shim &&
            selected['installed'] == wrapper &&
            selected['node'] == proof['node_executable'] &&
            selected['version'] == 'v24.21.0' &&
            selected['dart'] == null &&
            paths.split(wrapper).contains('_npx'),
        'npm actual exec selection differs',
      );
    }
    const groups = [
      'core',
      'assets',
      'commands',
      'runtimes',
      'corpus',
      'termination',
    ];
    requireReceipt(
      ranges.length == groups.length && groups.every(ranges.containsKey),
      'npm phase process ranges differ',
    );
    final slices = <String, List<InstalledProcessEvidence>>{};
    for (final group in groups) {
      final range = receiptList(ranges[group]);
      requireReceipt(
        range.length == 2 &&
            range.every((value) => value is int) &&
            range[0] >= 0 &&
            range[1] >= range[0] &&
            range[1] <= processes.length,
        'Invalid npm original process range',
      );
      if (cursor == null) {
        validateNpmSetupProcesses(
          processes.sublist(0, range[0] as int),
          proof,
          phase,
          route: route,
          target: target,
          acquisitionMode: acquisitionMode,
        );
        cursor = range[0] as int;
      }
      requireReceipt(
        range[0] == cursor,
        'npm process ranges overlap or omit original captures',
      );
      slices[group] = processes.sublist(range[0] as int, range[1] as int);
      cursor = range[1] as int;
    }
    final native = paths.join(
      payload,
      'bin',
      target,
      target == 'windows-x64' ? 'archway.exe' : 'archway',
    );
    validateInstalledCoreReceipts(phase['core']);
    validateInstalledCoreProcesses(
      slices['core']!,
      repository: repository,
      version: descriptor['version'] as String,
      prefix: prefix,
      project: project,
      target: target,
    );
    validateNpmExpanded(
      {
        'asset_controls': phase['assets'],
        'command_controls': phase['commands'],
        'runtime_controls': phase['runtimes'],
        'corpus_control': phase['corpus'],
      },
      target,
      route,
      artifact,
      selectedInstalledPath:
          'node_modules/archway-architecture-cli/bin/archway.cjs',
    );
    validateInstalledAssetProcesses(
      slices['assets']!,
      output: output,
      prefix: prefix,
      project: project,
      launcherErrorPrefix: 'archway launcher:',
    );
    validateInstalledCommandProcesses(
      slices['commands']!,
      output: output,
      prefix: prefix,
      project: project,
      nativeExecutable: native,
    );
    validateNpmRuntimeProcesses(
      slices['runtimes']!,
      output: output,
      prefix: prefix,
      project: project,
      nativeExecutable: native,
      wrongNode: runtime['executable'] as String,
      target: target,
    );
    validateNpmCorpusProcesses(
      slices['corpus']!,
      output: output,
      prefix: prefix,
      project: project,
      route: route,
    );
    validateNpmUnsupportedProcess(
      slices['termination']!,
      node: proof['node_executable'] as String,
      launcher: paths.join(wrapper, 'bin', 'archway.cjs'),
    );
    validateNpmTermination(
      {'termination_control': phase['termination']},
      target,
      route,
      proof['node'],
      proof['npm'],
    );
    requireReceipt(
      terminationDirectories.add(phase['termination_directory'] as String),
      'Duplicate npm termination evidence directory',
    );
    validateNpmTerminationEvidence(
      phase,
      directory,
      target: target,
      route: route,
      prefix: prefix,
      outputValidator: output,
    );
  }
  requireReceipt(
    cursor == processes.length,
    'Unclaimed original npm process captures',
  );
}
