// Exact shared inventories for independently retained installed controls.
import 'release_receipt_values.dart';

void validateInstalledAssetReceipts(Object? receipt) {
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
    exactReceipt(receipt, assets),
    'Installed asset-control inventory/results differ',
  );
}

void validateInstalledCommandReceipts(Object? receipt) {
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
    exactReceipt(receipt, commands),
    'Installed command/argv/native parity or bridge controls differ',
  );
}

void validateInstalledCoreReceipts(Object? receipt) {
  final core = receiptObject(receipt);
  requireReceipt(
    exactReceipt(core, {
      'native_commands': ['help', 'version', 'init', 'validate', 'export'],
      'typescript': [
        for (final row in const [
          ('clean', 0, 'ok', true),
          ('dependency-violation', 1, 'negative', true),
          ('unsupported-option', 64, 'usage_error', null),
          ('missing-owned-helper', 2, 'incomplete', false),
          ('restored-clean', 0, 'ok', true),
        ])
          {
            'case': row.$1,
            'command': 'check',
            'exit': row.$2,
            'status': row.$3,
            'analysis_complete': row.$4,
          },
      ],
    }),
    'Installed native/TypeScript core coverage differs',
  );
}
