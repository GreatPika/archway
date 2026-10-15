import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/release_installed_control_receipts.dart';

void main() {
  test('core receipt preserves five original classifications and exact integer statuses', () {
    final fixture = {
      'native_commands': ['help', 'version', 'init', 'validate', 'export'],
      'typescript': [
        {
          'case': 'clean',
          'command': 'check',
          'exit': 0,
          'status': 'ok',
          'analysis_complete': true,
        },
        {
          'case': 'dependency-violation',
          'command': 'check',
          'exit': 1,
          'status': 'negative',
          'analysis_complete': true,
        },
        {
          'case': 'unsupported-option',
          'command': 'check',
          'exit': 64,
          'status': 'usage_error',
          'analysis_complete': null,
        },
        {
          'case': 'missing-owned-helper',
          'command': 'check',
          'exit': 2,
          'status': 'incomplete',
          'analysis_complete': false,
        },
        {
          'case': 'restored-clean',
          'command': 'check',
          'exit': 0,
          'status': 'ok',
          'analysis_complete': true,
        },
      ],
    };
    validateInstalledCoreReceipts(fixture);
    for (final mutate in <void Function(Map)>[
      (value) => (value['typescript'] as List).removeAt(3),
      (value) => value['typescript'][3]['analysis_complete'] = true,
      (value) => value['typescript'][2]['exit'] = 64.0,
      (value) => (value['native_commands'] as List).remove('export'),
    ]) {
      final changed = jsonDecode(jsonEncode(fixture)) as Map;
      mutate(changed);
      expect(
        () => validateInstalledCoreReceipts(changed),
        throwsFormatException,
      );
    }
  });
}
