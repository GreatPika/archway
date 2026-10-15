import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/release_installed_output_receipts.dart';
import '../tool/ci/release_installed_process_receipts.dart';

void main() {
  test(
    'installed output uses public schemas and exact original diagnostics',
    () {
      final validator = InstalledOutputValidator(Directory.current, '2.3.4');
      final original = jsonDecode(
        File('contracts/json/fixtures/check-tool-error.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      original['tool_versions']['archway'] = '2.3.4';
      original['status'] = 'incomplete';
      original['payload']['tool_errors'][0]['code'] =
          'TYPESCRIPT_ASSETS_UNAVAILABLE';
      original['diagnostics'] = original['payload']['tool_errors'];
      InstalledProcessEvidence row(Map value, {List<int> stderr = const []}) =>
          (
            arguments: ['/sdk/dart', '--root', '/project', 'check'],
            exitCode: 2,
            stdout: utf8.encode('${jsonEncode(value)}\n'),
            stderr: stderr,
          );
      void admit(InstalledProcessEvidence process) => validator.publicResult(
        process,
        command: 'check',
        code: 2,
        status: 'incomplete',
        error: 'TYPESCRIPT_ASSETS_UNAVAILABLE',
        analysisComplete: false,
      );
      admit(row(original));
      for (final change in <void Function(Map)>[
        (v) => v['payload']['tool_errors'][0]['code'] = 'NODE_UNAVAILABLE',
        (v) => v.remove('tool_versions'),
        (v) => v['tool_versions']['archway'] = '0.1.0',
        (v) => v['payload']['analysis_complete'] = true,
        (v) => v['exit_code'] = 2.0,
      ]) {
        final changed = jsonDecode(jsonEncode(original)) as Map;
        change(changed);
        expect(() => admit(row(changed)), throwsFormatException);
      }
      expect(() => admit(row(original, stderr: [120])), throwsFormatException);
    },
  );
  test(
    'installed export keeps diagnostics on stderr and refuses wrong errors',
    () {
      final validator = InstalledOutputValidator(Directory.current, '2.3.4');
      final value = jsonDecode(
        File('contracts/json/fixtures/export-error.json').readAsStringSync(),
      ) as Map;
      value['tool_versions']['archway'] = '2.3.4';
      value['diagnostics'][0]['code'] = 'EXPORT_WRITE_FAILED';
      InstalledProcessEvidence row({List<int> stdout = const []}) => (
        arguments: ['/wrapper', 'export', '--out', 'diagram.mmd'],
        exitCode: 2,
        stdout: stdout,
        stderr: utf8.encode('${jsonEncode(value)}\n'),
      );
      void admit(InstalledProcessEvidence process) => validator.exportResult(
        process,
        code: 2,
        status: 'error',
        error: 'EXPORT_WRITE_FAILED',
        fileOutput: true,
      );
      admit(row());
      expect(() => admit(row(stdout: [120])), throwsFormatException);
      value['diagnostics'][0]['code'] = 'OTHER_ERROR';
      expect(() => admit(row()), throwsFormatException);
    },
  );
  test('unknown-command usage explicitly admits a null command', () {
    final validator = InstalledOutputValidator(Directory.current, '2.3.4');
    final value = jsonDecode(
      File('contracts/json/fixtures/check-usage.json').readAsStringSync(),
    ) as Map;
    value['command'] = null;
    value['resolved_root'] = null;
    value['tool_versions']['archway'] = '2.3.4';
    value['diagnostics'][0]['code'] = 'USAGE_ERROR';
    final InstalledProcessEvidence row = (
      arguments: ['/wrapper', 'unknown'],
      exitCode: 64,
      stdout: utf8.encode('${jsonEncode(value)}\n'),
      stderr: [],
    );
    validator.publicResult(
      row,
      command: null,
      code: 64,
      status: 'usage_error',
      error: 'USAGE_ERROR',
    );
    expect(
      () => validator.publicResult(
        row,
        command: 'check',
        code: 64,
        status: 'usage_error',
      ),
      throwsFormatException,
    );
  });
}
