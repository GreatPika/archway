import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_npm_expanded_receipts.dart';
import 'npm_expanded_receipt_fixtures.dart';

void main() {
  test('Windows original runtime requires a complete drive or UNC root', () {
    final directory = Directory.systemTemp.createTempSync('npm-runtime-path-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final proof = npmExpandedFixture(directory, 'windows-x64', 'local');
    final file = File(p.join(directory.path, 'runtime.json'));
    final record = jsonDecode(file.readAsStringSync()) as Map;
    void validate() =>
        validateNpmExpanded(proof, 'windows-x64', 'local', directory);
    for (final path in [
      r'\\server\share\node.exe',
      '//server/share/node.exe',
      r'C:\fixture\node.exe',
      r'\\?\C:\node.exe',
      r'\\?\UNC\server\share',
      '//?/UNC/server/share/node.exe',
      r'\\?\Volume{fixture}\node.exe',
      r'\\.\pipe\node',
      r'\\.\PhysicalDrive0\',
      r'\\?\GLOBALROOT\Device\HarddiskVolume1\node.exe',
    ]) {
      record['executable'] = path;
      file.writeAsStringSync(jsonEncode(record));
      validate();
    }
    for (final path in [
      r'\\server',
      '//server',
      r'\root-relative\node.exe',
      r'C:node.exe',
      r'\\?\C:',
      r'\\?\C:node.exe',
      r'\\?\UNC',
      r'\\?\UNC\server',
      r'\\?\Volume{fixture}',
      r'\\.\pipe',
      r'\\.\PhysicalDrive0',
      r'\\?\GLOBALROOT',
    ]) {
      record['executable'] = path;
      file.writeAsStringSync(jsonEncode(record));
      expect(validate, throwsFormatException, reason: path);
    }
  });
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    for (final route in ['local', 'global', 'cache']) {
      test(
        '$target $route requires asset, corpus, command and runtime results',
        () {
          final directory = Directory.systemTemp.createTempSync(
            'npm-receipts-',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          final original = npmExpandedFixture(directory, target, route);
          void validate(Map<String, dynamic> proof) =>
              validateNpmExpanded(proof, target, route, directory);
          validate(original);
          for (final mutate in <void Function(Map)>[
            (p) => (p['asset_controls'] as List).removeLast(),
            (p) => p['asset_controls'][0]['exit'] = 0,
            (p) => p['corpus_control']['applicable'] = route != 'local',
            (p) => (p['command_controls'] as List).removeLast(),
            (p) => p['command_controls'][3]['arguments'] = ['rewritten argv'],
            (p) => p['command_controls'][0]['native_parity'] = false,
            (p) => p['runtime_controls']['wrong_node']['executable_sha256'] =
                '0' * 64,
            (p) => p['runtime_controls']['cases'][1]['exit'] = 0,
            (p) =>
                p['runtime_controls']['cases'][0]['invocation'] = 'native-only',
            (p) => p['runtime_controls']['cases'][1]['exit'] = 127.0,
          ]) {
            final changed =
                jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
            mutate(changed);
            expect(() => validate(changed), throwsFormatException);
          }
        },
      );
    }
  }
}
