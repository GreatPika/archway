import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/release_installed_core_processes.dart';
import '../tool/ci/release_installed_process_receipts.dart';

void main() {
  for (final windows in [false, true]) {
    test(
      'core receipts bind ${windows ? 'Windows' : 'POSIX'} logical route and results',
      () {
        final prefix = [
          windows ? r'C:\sdk\dart.exe' : '/sdk/dart',
          'pub',
          'global',
          'run',
          'archway:archway',
        ];
        final project = windows ? r'C:\work\project' : '/work/project';
        final init = windows ? r'C:\work\init' : '/work/init';
        Map<String, dynamic> example(String name, String root) {
          final value = jsonDecode(
            File('contracts/json/fixtures/$name.json').readAsStringSync(),
          ) as Map<String, dynamic>;
          value['tool_versions']['archway'] = '2.3.4';
          value['resolved_root'] = root;
          return value;
        }

        InstalledProcessEvidence row(
          List<String> args,
          int exit, {
          String out = '',
          String err = '',
        }) => (
          arguments: [...prefix, ...args],
          exitCode: exit,
          stdout: utf8.encode(out),
          stderr: utf8.encode(err),
        );
        String line(Map value) => '${jsonEncode(value)}\n';
        final records = <InstalledProcessEvidence>[
          row(['--help'], 0, out: 'archway [--root ROOT] COMMAND\n'),
          row(['--version'], 0, out: 'archway 2.3.4\n'),
          row(
            ['--root', init, 'init', '--template', 'mixed'],
            0,
            out: line(example('init-created', init)),
          ),
          row(
            ['--root', init, 'validate'],
            0,
            out: line(example('validate-ok', init)),
          ),
          row(
            ['--root', init, 'export', '--format', 'mermaid'],
            0,
            out: 'flowchart LR\n',
            err: line(example('export-ok', init)),
          ),
        ];
        for (final (name, code, status) in [
          ('check-empty', 0, 'ok'),
          ('check-violations', 1, 'negative'),
          ('check-usage', 64, 'usage_error'),
          ('check-tool-error', 2, 'incomplete'),
          ('check-empty', 0, 'ok'),
        ]) {
          final value = example(name, project)..['status'] = status;
          if (code == 64) value['resolved_root'] = null;
          if (code != 64) {
            final payload = value['payload'] as Map;
            if (code == 2) {
              payload['tool_errors'][0]['code'] =
                  'TYPESCRIPT_ASSETS_UNAVAILABLE';
              value['diagnostics'] = payload['tool_errors'];
            } else {
              value['tool_versions']['typescript'] = '5.9.3';
              payload['observed'] = {
                'files': 2,
                'analyzed_files': 2,
                'edges': code,
              };
              payload['unknowns'] = [];
              if (code == 1)
                payload['violations'][0]['code'] = 'DEPENDENCY_NOT_ALLOWED';
            }
          }
          records.add(
            row(
              ['--root', project, 'check', if (code == 64) '--unsupported'],
              code,
              out: line(value),
            ),
          );
        }
        void admit(List<InstalledProcessEvidence> rows) =>
            validateInstalledCoreProcesses(
              rows,
              repository: Directory.current,
              version: '2.3.4',
              prefix: prefix,
              project: project,
              target: windows ? 'windows-x64' : 'linux-x64',
            );
        admit(records);
        expect(
          () => admit(
            [
              ...records,
            ]..[0] = row(['--help'], 0, out: 'unrelated invalid help --root\n'),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'reason',
              'Installed help/version output differs',
            ),
          ),
        );
        expect(() => admit(records.sublist(0, 9)), throwsFormatException);
        final first = records[5];
        final changed = [...records];
        changed[5] = (
          arguments: [...prefix, '--root', init, 'check'],
          exitCode: first.exitCode,
          stdout: first.stdout,
          stderr: first.stderr,
        );
        expect(() => admit(changed), throwsFormatException);
        final value = jsonDecode(utf8.decode(first.stdout)) as Map;
        value['payload']['observed']['files'] = 3;
        changed[5] = (
          arguments: first.arguments,
          exitCode: first.exitCode,
          stdout: utf8.encode(line(value)),
          stderr: first.stderr,
        );
        expect(() => admit(changed), throwsFormatException);
      },
    );
  }
}
