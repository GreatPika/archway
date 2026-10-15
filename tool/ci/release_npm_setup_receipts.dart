// Exact npm installation/acquisition commands precede all inspected core phases.
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../npm/native_preparation_command.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

void validateNpmSetupProcesses(
  List<InstalledProcessEvidence> processes,
  Map<String, dynamic> proof,
  Map<String, dynamic> phase, {
  required String route,
  required String target,
  required String acquisitionMode,
}) {
  final private = acquisitionMode == 'ci-verified-native';
  requireReceipt(
    processes.length == (private ? 4 : 3),
    'npm setup process inventory differs',
  );
  final node = proof['node_executable'] as String,
      npm = proof['npm_cli'] as String,
      archive = proof['archive_path'] as String;
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final prefix = List<String>.from(receiptList(phase['command_prefix']));
  final version = processes[0];
  requireReceipt(
    exactReceipt(version.arguments, [node, npm, '--version']) &&
        version.exitCode == 0 &&
        version.stderr.isEmpty &&
        utf8.decode(version.stdout).trim() == '11.19.0',
    'Original pinned npm version differs',
  );
  final install = processes[1];
  requireReceipt(install.exitCode == 0, 'npm route preparation failed');
  if (route == 'cache') {
    requireReceipt(
      install.arguments.length == 10 &&
          exactReceipt(install.arguments.take(9).toList(), [
            node,
            npm,
            'exec',
            '--offline',
            '--ignore-scripts',
            '--yes',
            '--package=$archive',
            '--',
            'node',
          ]) &&
          paths.isAbsolute(install.arguments.last) &&
          paths.basename(install.arguments.last) == 'npm cache locator.cjs' &&
          install.stderr.isEmpty,
      'npm cache selection command differs',
    );
    requireReceipt(
      exactReceipt(
        jsonDecode(utf8.decode(install.stdout)),
        proof['cache_selection'],
      ),
      'Original npm cache selection differs',
    );
  } else {
    final root = route == 'local'
        ? phase['project'] as String
        : target == 'windows-x64'
        ? paths.dirname(phase['shim'] as String)
        : paths.dirname(paths.dirname(phase['shim'] as String));
    requireReceipt(
      exactReceipt(install.arguments, [
        node,
        npm,
        'install',
        route == 'local' ? '-D' : '--global',
        '--prefix',
        root,
        archive,
        '--offline',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
      ]),
      'npm installation argv differs',
    );
  }
  if (private) {
    final prepared = processes[2], args = processes[2].arguments;
    final cache = paths.dirname(
      paths.dirname(paths.dirname(phase['payload'] as String)),
    );
    requireReceipt(
      args.length == 8 &&
          args[0] == node &&
          args[1] == '--eval' &&
          args[2] == npmNativePreparationProgram &&
          exactReceipt(args.sublist(3, 7), [
            paths.join(phase['wrapper'] as String, 'bin', 'cache.cjs'),
            paths.join(phase['wrapper'] as String, 'acquisition.json'),
            target,
            cache,
          ]) &&
          paths.isAbsolute(args.last) &&
          paths.basename(args.last) == 'input' &&
          prepared.exitCode == 0 &&
          prepared.stdout.isEmpty &&
          prepared.stderr.isEmpty,
      'Private verified-native preparation command differs',
    );
  }
  final help = processes.last;
  requireReceipt(
    exactReceipt(help.arguments, [...prefix, '--help']) &&
        help.exitCode == 0 &&
        help.stderr.isEmpty &&
        utf8.decode(help.stdout).startsWith('archway [--root ROOT]'),
    'Acquired native first launch differs',
  );
}
