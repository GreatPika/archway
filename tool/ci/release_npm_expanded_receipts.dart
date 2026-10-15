// Expanded npm installed-route controls and original prepared runtime identity.
import 'dart:io';

import 'native_fixture_pins.dart';
import 'release_receipt_values.dart';
import 'release_installed_control_receipts.dart';
import 'release_installed_runtime_identity.dart';

void validateNpmExpanded(
  Map<String, dynamic> receipt,
  String target,
  String route,
  Directory artifact, {
  String selectedInstalledPath =
      'node_modules/archway-architecture-cli/assets/typescript/helper.cjs',
}) {
  requireReceipt(
    fixtureWrongNodePins.containsKey(target) &&
        ['local', 'global', 'cache'].contains(route),
    'Unknown npm target or route',
  );
  validateInstalledAssetReceipts(receipt['asset_controls']);
  final corpus = route == 'local'
      ? {
          'applicable': true,
          'selected_path': selectedInstalledPath,
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
  validateInstalledCommandReceipts(receipt['command_controls']);
  final runtime = receiptObject(receipt['runtime_controls']);
  validateInstalledWrongNodeReceipt(runtime['wrong_node'], target, artifact);
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
