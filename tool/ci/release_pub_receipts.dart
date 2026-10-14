// Verify installed pub analysis against original streams and public schemas.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/json_schema.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

void validatePubReceipt(
  Map<String, dynamic> proof,
  Directory artifact,
  String target,
  Directory repository,
) {
  final platform = {
    'linux-x64': 'linux',
    'macos-arm64': 'darwin',
    'windows-x64': 'win32',
  }[target];
  requireReceipt(platform != null, 'Unsupported pub target');
  final analysis = receiptObject(proof['analysis']);
  final cases = receiptList(analysis['cases']);
  const expected = [
    ('init', ['init', '--template', 'mixed'], 0, false, null),
    ('validate', ['validate'], 0, false, null),
    ('node', ['node'], 0, false, null),
    ('export-stdout', ['export', '--format', 'mermaid'], 0, false, null),
    (
      'export-file',
      ['export', '--format', 'mermaid', '--out', 'diagram.mmd'],
      0,
      false,
      null,
    ),
    ('typescript', ['check'], 0, true, null),
    ('missing-node', ['check'], 2, false, 'NODE_UNAVAILABLE'),
    ('missing-helper', ['check'], 2, true, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('aliased-helper', ['check'], 2, true, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('restored-typescript', ['check'], 0, true, null),
    ('missing-bridge-validate', ['validate'], 0, false, null),
    (
      'missing-bridge-export',
      ['export', '--format', 'mermaid', '--out', 'blocked.mmd'],
      2,
      false,
      'EXPORT_WRITE_FAILED',
    ),
    (
      'missing-bridge-init',
      ['init', '--template', 'mixed'],
      2,
      false,
      'INIT_UNAVAILABLE',
    ),
  ];
  requireReceipt(
    exactReceipt(analysis['node'], {
          'version': 'v24.21.0',
          'platform': platform,
          'arch': target == 'macos-arm64' ? 'arm64' : 'x64',
        }) &&
        cases.length == expected.length,
    'Pub expanded analysis runtime/inventory differs',
  );
  final schemas = {
    for (final name in ['public-result', 'export-diagnostics'])
      name: ContractSchema(
        readRecord(
          File(p.join(repository.path, 'contracts/json/$name.schema.json')),
        ),
      ),
  };
  for (var index = 0; index < cases.length; index++) {
    final receipt = receiptObject(cases[index]);
    final (name, args, code, node, error) = expected[index];
    requireReceipt(
      exactReceipt(
        [
          receipt['case'],
          receipt['arguments'],
          receipt['exit'],
          receipt['node_available'],
          receipt['error'],
        ],
        [name, args, code, node, error],
      ),
      'Pub expanded analysis case differs',
    );
    final stdout = verifiedBytes(
      oneReceiptFile(artifact, '$name.stdout.log'),
      receipt['stdout_sha256'],
    );
    final stderr = verifiedBytes(
      oneReceiptFile(artifact, '$name.stderr.log'),
      receipt['stderr_sha256'],
    );
    final export = args.first == 'export';
    if (name == 'export-stdout') {
      requireReceipt(
        utf8.decode(stdout).endsWith('flowchart LR\n'),
        'Pub actual Mermaid output differs',
      );
    }
    requireReceipt(
      !(export && args.contains('--out')) || stdout.isEmpty,
      'Pub file export unexpectedly wrote stdout',
    );
    requireReceipt(
      export || stderr.isEmpty,
      'Pub command emitted unexpected stderr',
    );
    final data = export ? stderr : stdout;
    if (data.isEmpty) {
      if (export && code == 0 && error == null) continue;
      throw const FormatException('Pub command omitted required JSON evidence');
    }
    final value = receiptObject(decodeEvidenceJson(utf8.decode(data)));
    final status = code == 0
        ? 'ok'
        : args.first == 'check'
        ? 'incomplete'
        : 'error';
    requireReceipt(
      schemas[export ? 'export-diagnostics' : 'public-result']!
              .errors(value)
              .isEmpty &&
          value['command'] == args.first &&
          value['exit_code'] is int &&
          value['exit_code'] == code &&
          value['status'] == status,
      'Pub actual JSON schema/command/exit differs',
    );
    if (error != null) {
      final errors = receiptList(
        args.first == 'check'
            ? receiptObject(value['payload'])['tool_errors']
            : value['diagnostics'],
      );
      requireReceipt(
        exactReceipt(errors.map((e) => receiptObject(e)['code']).toList(), [
          error,
        ]),
        'Pub actual JSON error codes differ',
      );
    }
    if (args.first == 'check') {
      requireReceipt(
        receiptObject(value['payload'])['analysis_complete'] == (code == 0),
        'Pub actual analysis completeness differs',
      );
    }
  }
}
