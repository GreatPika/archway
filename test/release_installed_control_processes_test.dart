// Synthetic rows discriminate receipt binding; real routes have separate evidence.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/release_installed_control_processes.dart';
import '../tool/ci/release_installed_output_receipts.dart';
import '../tool/ci/release_installed_process_receipts.dart';

void main() {
  const prefix = ['/wrapper/archway'],
      native = '/payload/archway',
      project = '/project';
  final validator = InstalledOutputValidator(Directory.current, '2.3.4');
  Map<String, dynamic> example(String name) {
    final value = jsonDecode(
      File('contracts/json/fixtures/$name.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    value['tool_versions']['archway'] = '2.3.4';
    value['resolved_root'] = project;
    return value;
  }

  String line(Map value) => '${jsonEncode(value)}\n';
  InstalledProcessEvidence row(
    List<String> args,
    int exit, {
    String out = '',
    String err = '',
  }) => (
    arguments: args,
    exitCode: exit,
    stdout: utf8.encode(out),
    stderr: utf8.encode(err),
  );
  test(
    'asset receipt binds actual route root error and prelaunch channels',
    () {
      final rows = <InstalledProcessEvidence>[];
      for (final error in [
        'TYPESCRIPT_ASSETS_UNAVAILABLE',
        'TYPESCRIPT_HELPER_FAILED',
        'TYPESCRIPT_ASSETS_UNAVAILABLE',
        'TYPESCRIPT_ASSETS_UNAVAILABLE',
        'TYPESCRIPT_LOAD_FAILED',
      ]) {
        final value = example('check-tool-error');
        value['status'] = 'incomplete';
        value['payload']['tool_errors'][0]['code'] = error;
        value['diagnostics'] = value['payload']['tool_errors'];
        rows.add(
          row([...prefix, '--root', project, 'check'], 2, out: line(value)),
        );
      }
      for (var i = 0; i < 6; i++)
        rows.add(
          row(
            [...prefix, '--help'],
            126,
            err: 'archway launcher: unavailable\n',
          ),
        );
      rows.add(row([...prefix, '--help'], 0, out: 'archway [--root ROOT]\n'));
      void admit() => validateInstalledAssetProcesses(
        rows,
        output: validator,
        prefix: prefix,
        project: project,
        launcherErrorPrefix: 'archway launcher:',
      );
      admit();
      final original = rows[0];
      rows[0] = (
        arguments: ['/other/archway', ...original.arguments.skip(1)],
        exitCode: original.exitCode,
        stdout: original.stdout,
        stderr: original.stderr,
      );
      expect(admit, throwsFormatException);
      rows[0] = original;
      rows[5] = row(
        [...prefix, '--help'],
        126,
        out: 'must stay empty',
        err: 'archway launcher: unavailable\n',
      );
      expect(admit, throwsFormatException);
    },
  );
  test('command receipt binds native parity literal argv and bridge-only export failure', () {
    final rows = <InstalledProcessEvidence>[];
    for (final (operation, fixture, code) in [
      (['validate'], 'validate-ok', 0),
      (['node'], 'node-catalogue', 0),
      (['export', '--format', 'mermaid'], 'export-ok', 0),
      (
        [r'unknown; $(touch should-not-exist) & café'],
        'unknown-command-usage',
        64,
      ),
    ]) {
      final value = example(fixture);
      if (code == 64) {
        value['resolved_root'] = null;
        value['diagnostics'][0]['code'] = 'USAGE_ERROR';
      }
      for (final command in [
        [native],
        prefix,
      ])
        rows.add(
          row(
            [...command, '--root', project, ...operation],
            code,
            out: fixture == 'export-ok' ? 'flowchart LR\n' : line(value),
            err: fixture == 'export-ok' ? line(value) : '',
          ),
        );
    }
    rows.add(
      row(
        [...prefix, '--root', project, 'validate'],
        0,
        out: line(example('validate-ok')),
      ),
    );
    final export = [
      ...prefix,
      '--root',
      project,
      'export',
      '--format',
      'mermaid',
      '--out',
      'bridge output café.mmd',
    ];
    final error = example('export-error');
    error['diagnostics'][0]['code'] = 'EXPORT_WRITE_FAILED';
    rows.add(row(export, 2, err: line(error)));
    rows.add(row(export, 0));
    void admit() => validateInstalledCommandProcesses(
      rows,
      output: validator,
      prefix: prefix,
      project: project,
      nativeExecutable: native,
    );
    admit();
    final original = rows[7];
    rows[7] = (
      arguments: [...prefix, '--root', project, 'unknown'],
      exitCode: original.exitCode,
      stdout: original.stdout,
      stderr: original.stderr,
    );
    expect(admit, throwsFormatException);
    rows[7] = original;
    error['diagnostics'][0]['code'] = 'UNRELATED';
    rows[9] = row(export, 2, err: line(error));
    expect(admit, throwsFormatException);
  });
}
