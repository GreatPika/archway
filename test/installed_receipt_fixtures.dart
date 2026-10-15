// Synthetic original installed command streams, derived from contract examples.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_installer_receipt_fixtures.dart';

void addInstalledReceipts(InstallerEvidence e) {
  final binary = e.at(
    e.target == 'windows-x64'
        ? 'installed/bin/windows-x64/archway.exe'
        : 'installed/bin/${e.target}/archway',
  );
  final commands = [
    ['--help'],
    ['--version'],
    ['--root', '/project', 'init', '--template', 'mixed'],
    ['--root', '/project', 'validate'],
    ['--root', '/project', 'export', '--format', 'mermaid'],
    ['--root', '/project', 'check'],
    ['--root', '/project', 'check'],
    ['--root', '/project', 'check', '--unsupported'],
    ['--root', '/project', 'check'],
    ['--root', '/project', 'check'],
  ];
  const examples = {
    2: 'init-created',
    3: 'validate-ok',
    4: 'export-ok',
    5: 'check-empty',
    6: 'check-violations',
    7: 'check-usage',
    8: 'check-tool-error',
    9: 'check-tool-error',
  };
  const exits = [0, 0, 0, 0, 0, 0, 1, 64, 2, 2];
  final processes = <Map<String, dynamic>>[];
  for (var i = 0; i < commands.length; i++) {
    String stdout, stderr = '';
    if (i == 0) {
      stdout = 'archway [--root ROOT] SYNTHETIC\n';
    } else if (i == 1) {
      stdout = 'archway ${e.version}\n';
    } else {
      final value = jsonDecode(
        File('contracts/json/fixtures/${examples[i]}.json').readAsStringSync(),
      ) as Map;
      value['tool_versions']['archway'] = 'synthetic-unit-fixture';
      if (i == 3)
        value['payload'] = {'policy_valid': true, 'projects': 0, 'nodes': 0};
      if (i >= 8) {
        value['status'] = 'incomplete';
        value['diagnostics'] = value['payload']['tool_errors'];
      }
      stdout = '${jsonEncode(value)}\n';
      if (i == 4) {
        stderr = stdout;
        stdout = 'flowchart LR\n';
      }
    }
    processes.add(
      e.record(
        [binary, ...commands[i]],
        'installed-$i',
        exit: exits[i],
        stdout: stdout,
        stderr: stderr,
      ),
    );
  }
  final suites = <Map<String, dynamic>>[];
  final directory = Directory(p.join(e.directory.path, 'suites'))..createSync();
  for (final name in ['plan_query', 'dart_check']) {
    final record = <String, dynamic>{
      'suite': name,
      'command': [
        e.dart,
        '--suppress-analytics',
        'run',
        e.at('repo/test/${name}_process_smoke.dart'),
        binary,
        if (name == 'dart_check') ...[
          e.at('dart_sdk'),
          e.at('node'),
          '--existing-installation',
        ],
      ],
      'exit_code': 0,
      'timed_out': false,
      'elapsed_seconds': 1.0,
      'timeout_seconds': 600,
    };
    for (final stream in ['stdout', 'stderr']) {
      final bytes = utf8.encode(
        stream == 'stdout' ? 'SYNTHETIC suite fixture\n' : '',
      );
      File(p.join(directory.path, '$name.$stream.log')).writeAsBytesSync(bytes);
      record[stream] = '$name.$stream.log';
      record['${stream}_sha256'] = InstallerEvidence.hash(bytes);
    }
    File(p.join(directory.path, '$name.json'))
        .writeAsStringSync(jsonEncode(record));
    suites.add(record);
  }
  e.receipt['cases'] = [
    'install-old',
    'upgrade-final',
    'installed-command',
    'remove',
    'foreign-preserved',
    if (e.target == 'windows-x64') ...[
      'raw-path-registry-types',
      'preexisting-path-token',
      'foreign-root-refusal',
      'foreign-command-refusal',
      'duplicate-token-refusal',
      'root-junction-refusal',
      'locked-stale-file-failure',
      'obsolete-directory-junction-uninstall',
    ],
  ];
  e.receipt['installed'] = {
    'binary': binary,
    'installation_root': e.at('installed'),
    'manifest_sha256': e.manifest,
    'native_commands': ['help', 'version', 'init', 'validate', 'export'],
    'typescript': [
      {'case': 'clean', 'exit': 0},
      {'case': 'dependency-violation', 'exit': 1},
      {'case': 'unsupported-option', 'exit': 64},
    ],
    'runtime_controls': [
      for (final name in ['missing-node', 'wrong-node'])
        {
          'case': name,
          'exit': 2,
          'errors': ['NODE_UNAVAILABLE'],
        },
    ],
    'processes': processes,
    'suites': suites,
  };
}
