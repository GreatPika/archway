// Admit original ten-command core observations through a caller-bound route.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';
import 'release_installed_output_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

void validateInstalledCoreProcesses(
  List<InstalledProcessEvidence> commands, {
  required Directory repository,
  required String version,
  required List<String> prefix,
  required String project,
  required String target,
}) {
  requireReceipt(
    commands.length == 10 &&
        prefix.isNotEmpty &&
        ['linux-x64', 'macos-arm64', 'windows-x64'].contains(target),
    'Installed core process inventory or target differs',
  );
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  requireReceipt(
    paths.isAbsolute(project),
    'Installed project must be absolute',
  );
  final outputs = InstalledOutputValidator(repository, version);
  void argv(int index, List<String> tail) => requireReceipt(
    exactReceipt(commands[index].arguments, [...prefix, ...tail]),
    'Installed core logical command differs at $index',
  );
  void root(Map<String, dynamic> value, String expected) => requireReceipt(
    value['resolved_root'] is String &&
        sameEvidencePath(value['resolved_root'] as String, expected, paths),
    'Installed result root differs from command',
  );
  argv(0, ['--help']);
  argv(1, ['--version']);
  requireReceipt(
    commands[0].exitCode == 0 &&
        commands[0].stderr.isEmpty &&
        utf8.decode(commands[0].stdout).startsWith('archway [--root ROOT]') &&
        commands[1].exitCode == 0 &&
        commands[1].stderr.isEmpty &&
        [
          'archway $version\n',
          'archway $version\r\n',
        ].contains(utf8.decode(commands[1].stdout)),
    'Installed help/version output differs',
  );
  final initArgs = commands[2].arguments;
  requireReceipt(
    initArgs.length == prefix.length + 5,
    'Installed init argument count differs',
  );
  final init = initArgs[prefix.length + 1];
  requireReceipt(
    paths.isAbsolute(init),
    'Installed init root must be absolute',
  );
  argv(2, ['--root', init, 'init', '--template', 'mixed']);
  final initialized = outputs.publicResult(
    commands[2],
    command: 'init',
    code: 0,
    status: 'ok',
  );
  root(initialized, init);
  requireReceipt(
    exactReceipt(receiptObject(initialized['payload'])['created_paths'], [
          'architecture.yaml',
          'ARCHITECTURE.md',
        ]) &&
        receiptObject(initialized['payload'])['outcome'] == 'created',
    'Installed init did not create the two bootstrap files',
  );
  argv(3, ['--root', init, 'validate']);
  root(
    outputs.publicResult(
      commands[3],
      command: 'validate',
      code: 0,
      status: 'ok',
    ),
    init,
  );
  argv(4, ['--root', init, 'export', '--format', 'mermaid']);
  root(outputs.exportResult(commands[4], code: 0, status: 'ok')!, init);
  requireReceipt(
    utf8.decode(commands[4].stdout).endsWith('flowchart LR\n'),
    'Installed core Mermaid output differs',
  );
  const outcomes = [
    (0, 'ok'),
    (1, 'negative'),
    (64, 'usage_error'),
    (2, 'incomplete'),
    (0, 'ok'),
  ];
  for (var offset = 0; offset < outcomes.length; offset++) {
    final index = offset + 5;
    final (code, status) = outcomes[offset];
    argv(index, ['--root', project, 'check', if (code == 64) '--unsupported']);
    final value = outputs.publicResult(
      commands[index],
      command: 'check',
      code: code,
      status: status,
      error: code == 2 ? 'TYPESCRIPT_ASSETS_UNAVAILABLE' : null,
      analysisComplete: code == 64 ? null : code != 2,
    );
    if (code == 64) {
      if (value['resolved_root'] != null) root(value, project);
      requireReceipt(
        value['payload'] == null,
        'Usage output must have null payload',
      );
      continue;
    }
    root(value, project);
    final payload = receiptObject(value['payload']);
    requireReceipt(
      payload['policy_valid'] == true,
      'Installed check policy differs',
    );
    if (code == 2) continue;
    requireReceipt(
      receiptObject(value['tool_versions'])['typescript'] == '5.9.3' &&
          exactReceipt(payload['tool_errors'], []) &&
          exactReceipt(payload['unknowns'], []) &&
          exactReceipt(payload['observed'], {
            'files': 2,
            'analyzed_files': 2,
            'edges': code,
          }) &&
          exactReceipt(
            receiptList(payload['violations'])
                .map((row) => receiptObject(row)['code'])
                .toList(),
            code == 1 ? ['DEPENDENCY_NOT_ALLOWED'] : [],
          ),
      'Installed original TypeScript observations differ',
    );
  }
}
