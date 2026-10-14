// Expanded npm installed-route controls and original prepared runtime identity.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_fixture_pins.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

void validateNpmExpanded(
  Map<String, dynamic> receipt,
  String target,
  String route,
  Directory artifact,
) {
  requireReceipt(
    fixtureWrongNodePins.containsKey(target) &&
        ['local', 'global', 'cache'].contains(route),
    'Unknown npm target or route',
  );
  final assets = [
    for (final entry in const {
      'aliased-helper': 'TYPESCRIPT_ASSETS_UNAVAILABLE',
      'corrupt-helper': 'TYPESCRIPT_HELPER_FAILED',
      'missing-compiler': 'TYPESCRIPT_ASSETS_UNAVAILABLE',
      'aliased-compiler': 'TYPESCRIPT_ASSETS_UNAVAILABLE',
      'corrupt-compiler': 'TYPESCRIPT_LOAD_FAILED',
    }.entries)
      {'case': entry.key, 'exit': 2, 'error': entry.value},
    for (final name in [
      'missing-payload',
      'aliased-payload',
      'corrupt-payload',
      'missing-manifest',
      'aliased-manifest',
      'corrupt-manifest',
    ])
      {'case': name, 'exit': 126, 'error': 'launcher-prelaunch'},
    {'case': 'restored-payload-help', 'exit': 0},
  ];
  requireReceipt(
    exactReceipt(receipt['asset_controls'], assets),
    'npm asset-control inventory/results differ',
  );
  final corpus = route == 'local'
      ? {
          'applicable': true,
          'selected_path': 'node_modules/archway-architecture-cli/assets/typescript/helper.cjs',
          'cases': [
            {
              'case': 'selected-installed-corpus',
              'exit': 2,
              'selected_present': true,
              'observed_files': 3,
            },
            {
              'case': 'excluded-installed-corpus',
              'exit': 0,
              'selected_present': false,
              'observed_files': 2,
            },
          ],
        }
      : {
          'applicable': false,
          'reason': 'installation-outside-inspected-root',
          'cases': [],
        };
  requireReceipt(
    exactReceipt(receipt['corpus_control'], corpus),
    'npm selected/excluded installed-corpus controls differ',
  );
  final commands = [
    for (final entry in const [
      ('validate-native-parity', ['validate'], 0),
      ('node-native-parity', ['node'], 0),
      ('export-native-parity', ['export', '--format', 'mermaid'], 0),
      (
        'literal-argv-native-parity',
        [r'unknown; $(touch should-not-exist) & café'],
        64,
      ),
    ])
      {
        'case': entry.$1,
        'arguments': entry.$2,
        'exit': entry.$3,
        'native_parity': true,
      },
    {'case': 'missing-bridge-validate', 'exit': 0},
    {
      'case': 'missing-bridge-export',
      'exit': 2,
      'error': 'EXPORT_WRITE_FAILED',
    },
    {'case': 'restored-bridge-export', 'exit': 0},
  ];
  requireReceipt(
    exactReceipt(receipt['command_controls'], commands),
    'npm command/argv/native parity or bridge controls differ',
  );
  final runtime = receiptObject(receipt['runtime_controls']);
  final record = receiptObject(
    readRecord(oneReceiptFile(artifact, 'runtime.json')),
  );
  final windows = target == 'windows-x64';
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  final digest = record['executable_sha256'], executable = record['executable'];
  final pin = fixtureWrongNodePins[target]!;
  requireReceipt(
    record['target'] == target &&
        record['version'] == '24.19.0' &&
        record['url'] ==
            'https://nodejs.org/dist/v24.19.0/node-v24.19.0-${pin.archive}' &&
        record['archive_sha256'] == pin.sha256 &&
        executable is String &&
        executable.isNotEmpty &&
        !executable.contains('\u0000') &&
        (windows
            ? _absoluteWindows(executable)
            : paths.isAbsolute(executable)) &&
        digest is String &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) &&
        exactReceipt(runtime['wrong_node'], {
          'version': '24.19.0',
          'platform': {
            'linux-x64': 'linux',
            'macos-arm64': 'darwin',
            'windows-x64': 'win32',
          }[target],
          'arch': target == 'macos-arm64' ? 'arm64' : 'x64',
          'executable_sha256': digest,
        }),
    'npm negative Node identity differs from official prepared artifact',
  );
  final cases = receiptList(runtime['cases']);
  requireReceipt(
    cases.length == 4,
    'npm runtime failure/supplemental native controls differ',
  );
  final launcherExit = receiptObject(cases[1])['exit'];
  requireReceipt(
    launcherExit is int && launcherExit != 0,
    'npm missing launcher Node did not fail',
  );
  requireReceipt(
    exactReceipt(cases, [
      {
        'case': 'wrong-analysis-node',
        'invocation': 'installed-route',
        'exit': 2,
        'error': 'NODE_UNAVAILABLE',
      },
      {
        'case': 'missing-launcher-node',
        'invocation': 'installed-route',
        'exit': launcherExit,
        'launcher_stderr_only': true,
      },
      {
        'case': 'native-supplement-missing-node-check',
        'invocation': 'installed-native-supplement',
        'exit': 2,
        'error': 'NODE_UNAVAILABLE',
      },
      {
        'case': 'native-supplement-no-node-validate',
        'invocation': 'installed-native-supplement',
        'exit': 0,
      },
    ]),
    'npm runtime failure/supplemental native controls differ',
  );
}

// Windows namespace roots need their own separator; UNC roots need server/share.
bool _absoluteWindows(String value) {
  final path = value.replaceAll('/', r'\');
  if (path.toUpperCase().startsWith(r'\\?\UNC\')) {
    return RegExp(r'^[^\\]+\\[^\\]+(?:\\|$)').hasMatch(path.substring(8));
  }
  if (path.startsWith(r'\\?\') || path.startsWith(r'\\.\')) {
    return path.substring(4).indexOf(r'\') > 0;
  }
  return RegExp(r'^(?:[^\\]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))').hasMatch(path);
}
