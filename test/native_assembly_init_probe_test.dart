import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/native_assembly_init_probe.dart';
import 'support/native_process_support.dart';

void main() {
  test('assembly options reject a lone mixed compiler runtime', () {
    expect(
      () => AssemblyOptions.parse(['--dart-sdk', '/sdk']),
      throwsFormatException,
    );
    expect(
      () => AssemblyOptions.parse(['--node', '/node']),
      throwsFormatException,
    );
  });
  test('init-only rejects optional compiler checks', () {
    expect(
      () => AssemblyOptions.parse([
        '--init-only',
        '--dart-sdk',
        '/sdk',
        '--node',
        '/node',
      ]),
      throwsFormatException,
    );
  });
  test(
    'unknown and incomplete options fail rather than becoming build paths',
    () {
      for (final args in [
        ['--unknown'],
        ['--node'],
        ['--node', '--init-only'],
        ['positional'],
      ]) {
        expect(() => AssemblyOptions.parse(args), throwsFormatException);
      }
    },
  );
  test('paired runtimes and destination spelling are retained without leaf resolution', () {
    final options = AssemblyOptions.parse([
      '--dart-sdk=/sdk',
      '--node',
      '/node',
      '--artifact-directory',
      'leaf/../alias',
    ]);
    expect(options.initOnly, false);
    expect(options.values, {
      '--dart-sdk': '/sdk',
      '--node': '/node',
      '--artifact-directory': 'leaf/../alias',
    });
    expect(AssemblyOptions.parse(['--init-only']).initOnly, true);
  });
  test('actual command returns argument-error exit before assembly', () async {
    final result = await runNativeProcess(
      [
        Platform.resolvedExecutable,
        'tool/ci/native_assembly_init_probe.dart',
        '--dart-sdk',
        'missing',
      ],
      workingDirectory: Directory.current.path,
      timeout: const Duration(seconds: 30),
    );
    expect(result.exitCode, 2);
    expect(result.stdout, isEmpty);
    expect(
      String.fromCharCodes(result.stderr),
      contains('--dart-sdk and --node must be supplied together'),
    );
  });
}
