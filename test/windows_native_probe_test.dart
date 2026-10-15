import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test('Windows x64 CLI init creates both files in a fresh root', () async {
    // Existing approved CLI.run seam; the expected success comes from the
    // init contract. A Linux run or dependency/load failure is not Windows red.
    expect(Abi.current(), Abi.windowsX64);
    final runnerTemp = Platform.environment['RUNNER_TEMP'];
    final base = runnerTemp == null
        ? Directory.systemTemp
        : Directory(runnerTemp);
    final root = await base.createTemp('archway windows café ');
    print('CLI_TEST_ROOT=${root.path}');
    addTearDown(() => root.delete(recursive: true));
    final out = StringBuffer();
    final err = StringBuffer();
    final result = await CLI().run([
      'init',
      '--root',
      root.path,
      '--template',
      'mixed',
    ], CliStreams(out, err));
    // Keep the observed diagnostic before the assertion; do not bless exit 2.
    print('CLI_RUN_COMPLETED actual_exit=$result expected_exit=0');
    print('stdout=${out.toString()}');
    print('stderr=${err.toString()}');
    expect(result, 0, reason: 'Fresh-root init is contractually successful.');
    expect(err.toString(), isEmpty);
    final value = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(value['status'], 'ok');
    expect(value['exit_code'], 0);
    expect(value['payload']['outcome'], 'created');
    expect(await File('${root.path}/architecture.yaml').exists(), isTrue);
    expect(await File('${root.path}/ARCHITECTURE.md').exists(), isTrue);
    expect(await root.list().length, 2);
  }, skip: !Platform.isWindows ? 'Requires a real Windows runner.' : false);
}
