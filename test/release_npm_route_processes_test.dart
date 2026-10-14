import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/release_installed_output_receipts.dart';
import '../tool/ci/release_installed_process_receipts.dart';
import '../tool/ci/release_npm_route_processes.dart';

void main() {
  final output = InstalledOutputValidator(Directory.current, '2.3.4');
  const prefix = ['/wrapper/archway'],
      project = '/project',
      native = '/payload/archway';
  InstalledProcessEvidence row(
    List<String> args,
    int exit,
    String out, [
    String err = '',
  ]) => (
    arguments: args,
    exitCode: exit,
    stdout: utf8.encode(out),
    stderr: utf8.encode(err),
  );
  Map<String, dynamic> fixture(String name) {
    final value = jsonDecode(
      File('contracts/json/fixtures/$name.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    value['tool_versions']['archway'] = '2.3.4';
    value['resolved_root'] = project;
    return value;
  }

  test('runtime originals distinguish launcher absence from native analysis absence', () {
    final error = fixture('check-tool-error');
    error['status'] = 'incomplete';
    error['payload']['tool_errors'][0]['code'] = 'NODE_UNAVAILABLE';
    error['diagnostics'] = error['payload']['tool_errors'];
    final rows = [
      row(
        [
          '/wrong/node',
          '-p',
          'JSON.stringify([process.version,process.platform,process.arch])',
        ],
        0,
        '["v24.19.0","linux","x64"]\n',
      ),
      row([...prefix, '--root', project, 'check'], 2, '${jsonEncode(error)}\n'),
      row([...prefix, '--help'], 127, '', 'node: not found\n'),
      row([native, '--root', project, 'check'], 2, '${jsonEncode(error)}\n'),
      row(
        [native, '--root', project, 'validate'],
        0,
        '${jsonEncode(fixture('validate-ok'))}\n',
      ),
    ];
    void admit() => validateNpmRuntimeProcesses(
      rows,
      output: output,
      prefix: prefix,
      project: project,
      nativeExecutable: native,
      wrongNode: '/wrong/node',
      target: 'linux-x64',
    );
    admit();
    final original = rows[3];
    rows[3] = row(
      [...prefix, '--root', project, 'check'],
      2,
      '${jsonEncode(error)}\n',
    );
    expect(admit, throwsFormatException);
    rows[3] = original;
    rows[2] = row(
      [...prefix, '--help'],
      127,
      'unexpected',
      'node: not found\n',
    );
    expect(admit, throwsFormatException);
  });
  test(
    'unsupported target requires literal injection and prelaunch stderr only',
    () {
      final args = [
        '/runtime/node',
        '-e',
        "Object.defineProperty(process,'platform',{value:'freebsd'});require(process.argv[1]);",
        '/wrapper/archway.cjs',
      ];
      void admit(InstalledProcessEvidence value) =>
          validateNpmUnsupportedProcess(
            [value],
            node: '/runtime/node',
            launcher: '/wrapper/archway.cjs',
          );
      admit(
        row(
          args,
          126,
          '',
          'archway launcher: unsupported target freebsd/x64\n',
        ),
      );
      expect(() => admit(row(args, 126, '', 'ENOENT')), throwsFormatException);
      expect(
        () => admit(
          row(
            [...args]..[3] = '/other',
            126,
            '',
            'archway launcher: unsupported target freebsd/x64\n',
          ),
        ),
        throwsFormatException,
      );
    },
  );
}
