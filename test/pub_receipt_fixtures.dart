// Public output shapes come from versioned examples, not production rendering.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> pubReceiptFixture(Directory artifact, String target) {
  final cases = [
    ('init', ['init', '--template', 'mixed'], false, 'init-created', null),
    ('validate', ['validate'], false, 'validate-ok', null),
    ('node', ['node'], false, 'node-catalogue', null),
    (
      'export-stdout',
      ['export', '--format', 'mermaid'],
      false,
      'export-ok',
      null,
    ),
    (
      'export-file',
      ['export', '--format', 'mermaid', '--out', 'diagram.mmd'],
      false,
      'export-ok',
      null,
    ),
    ('typescript', ['check'], true, 'check-empty', null),
    ('missing-node', ['check'], false, 'check-tool-error', 'NODE_UNAVAILABLE'),
    (
      'missing-helper',
      ['check'],
      true,
      'check-tool-error',
      'TYPESCRIPT_ASSETS_UNAVAILABLE',
    ),
    (
      'aliased-helper',
      ['check'],
      true,
      'check-tool-error',
      'TYPESCRIPT_ASSETS_UNAVAILABLE',
    ),
    ('restored-typescript', ['check'], true, 'check-empty', null),
    ('missing-bridge-validate', ['validate'], false, 'validate-ok', null),
    (
      'missing-bridge-export',
      ['export', '--format', 'mermaid', '--out', 'blocked.mmd'],
      false,
      'export-error',
      'EXPORT_WRITE_FAILED',
    ),
    (
      'missing-bridge-init',
      ['init', '--template', 'mixed'],
      false,
      'init-root-access-error',
      'INIT_UNAVAILABLE',
    ),
  ];
  final directory = Directory(p.join(artifact.path, 'analysis'))..createSync();
  final receipts = <Map<String, dynamic>>[];
  for (final (name, arguments, nodeAvailable, example, error) in cases) {
    final value = jsonDecode(
      File('contracts/json/fixtures/$example.json').readAsStringSync(),
    ) as Map;
    value['tool_versions']['archway'] = 'synthetic-unit-fixture';
    value['resolved_root'] = '/synthetic-unit-fixture';
    if (error != null) {
      final diagnostics = arguments.first == 'check'
          ? value['payload']['tool_errors']
          : value['diagnostics'];
      diagnostics[0]['code'] = error;
      diagnostics[0]['message'] = 'Synthetic unit fixture only';
      if (arguments.first == 'check') {
        value['status'] = 'incomplete';
        value['diagnostics'] = diagnostics;
      }
    }
    final export = arguments.first == 'export';
    if (export && arguments.contains('--out'))
      value['payload']['out'] = arguments.last;
    final bytes = utf8.encode('${jsonEncode(value)}\n');
    final streams = {
      'stdout': export
          ? utf8.encode(
              name == 'export-stdout'
                  ? '%% Synthetic unit fixture only\nflowchart LR\n'
                  : '',
            )
          : bytes,
      'stderr': export ? bytes : <int>[],
    };
    final receipt = <String, dynamic>{
      'case': name,
      'arguments': arguments,
      'exit': value['exit_code'],
      'node_available': nodeAvailable,
      'error': error,
    };
    for (final stream in streams.entries) {
      File(p.join(directory.path, '$name.${stream.key}.log'))
          .writeAsBytesSync(stream.value);
      receipt['${stream.key}_sha256'] = sha256.convert(stream.value).toString();
    }
    receipts.add(receipt);
  }
  return {
    'analysis': {
      'node': {
        'version': 'v24.21.0',
        'platform': {
          'linux-x64': 'linux',
          'macos-arm64': 'darwin',
          'windows-x64': 'win32',
        }[target],
        'arch': target == 'macos-arm64' ? 'arm64' : 'x64',
      },
      'cases': receipts,
    },
  };
}
