// Independent synthetic summaries for installed-route admission contracts.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_acceptance_receipt_fixtures.dart' show nodeHashes;

Map<String, dynamic> npmExpandedFixture(
  Directory directory,
  String target,
  String route,
) {
  final platform = {
    'linux-x64': 'linux',
    'macos-arm64': 'darwin',
    'windows-x64': 'win32',
  }[target];
  final arch = target == 'macos-arm64' ? 'arm64' : 'x64';
  final record = {
    'target': target,
    'version': '24.19.0',
    'url':
        'https://nodejs.org/dist/v24.19.0/node-v24.19.0-${{'linux-x64': 'linux-x64.tar.gz', 'macos-arm64': 'darwin-arm64.tar.gz', 'windows-x64': 'win-x64.zip'}[target]}',
    'archive_sha256': nodeHashes[target],
    'executable': target == 'windows-x64'
        ? r'C:\fixture\node.exe'
        : '/fixture/node',
    'executable_sha256': 'a' * 64,
  };
  File(p.join(directory.path, 'runtime.json'))
      .writeAsStringSync(jsonEncode(record));
  final assets = <Map<String, Object?>>[
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
  return {
    'asset_controls': assets,
    'corpus_control': route == 'local'
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
          },
    'command_controls': [
      {
        'case': 'validate-native-parity',
        'arguments': ['validate'],
        'exit': 0,
        'native_parity': true,
      },
      {
        'case': 'node-native-parity',
        'arguments': ['node'],
        'exit': 0,
        'native_parity': true,
      },
      {
        'case': 'export-native-parity',
        'arguments': ['export', '--format', 'mermaid'],
        'exit': 0,
        'native_parity': true,
      },
      {
        'case': 'literal-argv-native-parity',
        'arguments': [r'unknown; $(touch should-not-exist) & café'],
        'exit': 64,
        'native_parity': true,
      },
      {'case': 'missing-bridge-validate', 'exit': 0},
      {
        'case': 'missing-bridge-export',
        'exit': 2,
        'error': 'EXPORT_WRITE_FAILED',
      },
      {'case': 'restored-bridge-export', 'exit': 0},
    ],
    'runtime_controls': {
      'wrong_node': {
        'version': '24.19.0',
        'platform': platform,
        'arch': arch,
        'executable_sha256': 'a' * 64,
      },
      'cases': [
        {
          'case': 'wrong-analysis-node',
          'invocation': 'installed-route',
          'exit': 2,
          'error': 'NODE_UNAVAILABLE',
        },
        {
          'case': 'missing-launcher-node',
          'invocation': 'installed-route',
          'exit': 127,
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
      ],
    },
  };
}
