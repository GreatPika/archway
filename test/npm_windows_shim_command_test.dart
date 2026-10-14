import 'dart:io';

import 'package:test/test.dart';

import '../tool/npm/windows_shim_command.dart';
import '../tool/ci/installed_command_recorder.dart';

void main() {
  const cmd = r'C:\Windows\System32\cmd.exe';
  const node = r'C:\Node\node.exe';
  // Exact cmd-shim8.0.0 output from the prepared npm11.19.0, not a hand-written shell surrogate.
  final source = File('test/fixtures/npm-shim-local.cmd').readAsStringSync();
  Matcher refusal(String reason) => throwsA(
    isA<ArgumentError>().having(
      (error) => error.message.toString(),
      'reason',
      contains(reason),
    ),
  );
  const environment = {'COMSPEC': cmd, 'PATHEXT': '.COM;.EXE;.BAT;.CMD'};
  test('npm shell encoder keeps local and global shim semantics explicit', () {
    for (final shim in [
      r'C:\local café\node_modules\.bin\archway.cmd',
      r'C:\global café\archway.cmd',
      r'C:\100% ready %_prog% %*\archway.cmd',
    ]) {
      final arguments = [
        shim,
        '',
        'a b',
        '&',
        '%VALUE%',
        '!VALUE!',
        'quote"',
        r'end\',
      ];
      final result = windowsNpmShimCommand(
        arguments,
        cmdExecutable: cmd,
        nodeExecutable: node,
        shimSource: shim.contains('node_modules')
            ? source
            : File('test/fixtures/npm-shim-global.cmd').readAsStringSync(),
        environment: environment,
      );
      expect(result.logicalArguments, arguments);
      expect(result.applicationName, cmd);
      expect(result.commandLine, contains('/d /s /v:off /e:on /c'));
      expect(result.commandLine, contains('""'));
      expect(result.commandLine, contains('^^^&'));
      expect(result.commandLine, contains('^^^%VALUE^^^%'));
      expect(result.commandLine, contains('^^^!VALUE^^^!'));
    }
  });
  test(
    'recorder refuses malformed npm commands before allocating evidence',
    () async {
      final output = Directory.systemTemp.createTempSync('npm-admission-');
      addTearDown(() => output.deleteSync(recursive: true));
      final recorder = InstalledCommandRecorder(
        output: output,
        windowsCommandFor: (arguments) => windowsNpmShimCommand(
          arguments,
          cmdExecutable: cmd,
          nodeExecutable: node,
          shimSource: source,
          environment: environment,
        ),
      );
      for (final (value, reason) in [
        ('new\nline', 'single-line'),
        ('&' * 3000, 'Windows cmd limit'),
      ]) {
        await expectLater(
          recorder.capture([r'C:\owned\archway.cmd', value]),
          refusal(reason),
        );
        expect(output.listSync(), isEmpty);
        expect(recorder.commands, isEmpty);
      }
    },
  );
  test('npm shell admission rejects control lines unknown expansions and exceeded budgets', () {
    for (final value in ['line\nnext', 'line\rnext', 'nul\u0000next']) {
      expect(
        () => windowsNpmShimCommand(
          [r'C:\owned\archway.cmd', value],
          cmdExecutable: cmd,
          nodeExecutable: node,
          shimSource: source,
          environment: environment,
        ),
        refusal('single-line'),
      );
    }
    for (final (template, reason) in [
      (source.replaceFirst('%dp0%', '%UNKNOWN%'), 'Unknown npm shim expansion'),
      ('${'x' * 8192}%*', 'Windows cmd limit'),
    ]) {
      expect(
        () => windowsNpmShimCommand(
          [r'C:\owned\archway.cmd'],
          cmdExecutable: cmd,
          nodeExecutable: node,
          shimSource: template,
          environment: environment,
        ),
        refusal(reason),
      );
    }
    expect(
      () => windowsNpmShimCommand(
        [r'C:\owned\archway.cmd', '&' * 3000],
        cmdExecutable: cmd,
        nodeExecutable: node,
        shimSource: source,
        environment: environment,
      ),
      refusal('Windows cmd limit'),
    );
  });
}
