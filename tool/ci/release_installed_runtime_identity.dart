// Original prepared wrong-Node identity shared by npm and pub admission.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_fixture_pins.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

void validateInstalledWrongNodeReceipt(
  Object? wrongNode,
  String target,
  Directory artifact,
) {
  requireReceipt(
    fixtureWrongNodePins.containsKey(target),
    'Unknown runtime target',
  );
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
        exactReceipt(wrongNode, {
          'version': '24.19.0',
          'platform': {
            'linux-x64': 'linux',
            'macos-arm64': 'darwin',
            'windows-x64': 'win32',
          }[target],
          'arch': target == 'macos-arm64' ? 'arm64' : 'x64',
          'executable_sha256': digest,
        }),
    'Installed negative Node identity differs from official prepared artifact',
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
