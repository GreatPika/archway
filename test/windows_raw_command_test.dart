import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';

import 'support/windows_command.dart';

void main() {
  test('raw Windows command preserves immutable logical argv separately from shell text', () {
    final arguments = [
      r'C:\Program Files\tool.cmd',
      'space café',
      'literal "quote"',
    ];
    final command = WindowsRawCommandLine(
      applicationName: r'C:\Windows\System32\cmd.exe',
      commandLine: 'trusted raw cmd syntax',
      logicalArguments: arguments,
    );
    arguments[1] = 'changed';
    expect(command.logicalArguments, [
      r'C:\Program Files\tool.cmd',
      'space café',
      'literal "quote"',
    ]);
    expect(() => command.logicalArguments.add('extra'), throwsUnsupportedError);
    command.validateFor([
      r'C:\Program Files\tool.cmd',
      'space café',
      'literal "quote"',
    ]);
    expect(() => command.validateFor(arguments), throwsArgumentError);
    expect(command.applicationName, r'C:\Windows\System32\cmd.exe');
    expect(command.commandLine, 'trusted raw cmd syntax');
  });
  test(
    'raw transport refuses invalid application NUL empty or oversized commands',
    () {
      for (final bad in ['cmd.exe', 'C:cmd.exe', 'C:\\bad\u0000.exe']) {
        expect(
          () => WindowsRawCommandLine(
            applicationName: bad,
            commandLine: 'valid',
            logicalArguments: ['logical'],
          ),
          throwsArgumentError,
        );
      }
      for (final line in ['', 'bad\u0000line', 'x' * 32767]) {
        expect(
          () => WindowsRawCommandLine(
            applicationName: r'C:\Windows\cmd.exe',
            commandLine: line,
            logicalArguments: ['logical'],
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => WindowsRawCommandLine(
          applicationName: r'C:\Windows\cmd.exe',
          commandLine: 'valid',
          logicalArguments: [],
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'recorded raw command identity is checked before evidence allocation',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'raw-identity-refused-',
      );
      addTearDown(() => output.deleteSync(recursive: true));
      final command = WindowsRawCommandLine(
        applicationName: r'C:\Windows\System32\cmd.exe',
        commandLine: 'trusted command',
        logicalArguments: [r'C:\owned\shim.cmd', 'expected'],
      );
      final recorder = InstalledCommandRecorder(output: output);
      await expectLater(
        recorder.capture([
          r'C:\owned\shim.cmd',
          'changed',
        ], windowsCommand: command),
        throwsArgumentError,
      );
      expect(output.listSync(), isEmpty);
      expect(recorder.commands, isEmpty);
    },
  );

  test(
    'raw Windows capture rejects unsupported host before reserving evidence',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'raw-command-rejected-',
      );
      addTearDown(() => output.deleteSync(recursive: true));
      final logical = [Platform.resolvedExecutable, '--version'];
      final command = WindowsRawCommandLine(
        applicationName: r'C:\Windows\System32\cmd.exe',
        commandLine: 'trusted raw line',
        logicalArguments: logical,
      );
      final recorder = InstalledCommandRecorder(
        output: output,
        windowsCommandFor: (arguments) {
          expect(arguments, logical);
          return command;
        },
      );
      await expectLater(recorder.capture(logical), throwsUnsupportedError);
      expect(output.listSync(), isEmpty);
      expect(recorder.commands, isEmpty);
    },
    skip: Platform.isWindows ? 'Non-Windows admission control.' : false,
  );

  test(
    'native raw cmd preserves builtin streams exit and execution metadata',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'raw cmd receipts café ',
      );
      addTearDown(() => output.deleteSync(recursive: true));
      final cmd = p.join(
        Platform.environment['SystemRoot']!,
        'System32/cmd.exe',
      );
      final logical = [
        cmd,
        '/d',
        '/s',
        '/v:off',
        '/c',
        'echo',
        'raw-stdout&echo',
        'raw-stderr>&2&exit',
        '/b',
        '37',
      ];
      final command = WindowsRawCommandLine(
        applicationName: cmd,
        commandLine: '"$cmd" /d /s /v:off /c "${logical.skip(5).join(' ')}"',
        logicalArguments: logical,
      );
      final recorder = InstalledCommandRecorder(output: output);
      final result = await recorder.capture(
        logical,
        windowsCommand: command,
        expectedExit: 37,
        workingDirectory: output.path,
        environment: Platform.environment,
      );
      expect(utf8.decode(result.stdout), 'raw-stdout\r\n');
      expect(utf8.decode(result.stderr), 'raw-stderr\r\n');
      expect(result.exitCode, 37);
      final proof = recorder.commands.single;
      expect(proof['arguments'], logical);
      expect(proof['windows_execution'], {
        'application_name': cmd,
        'command_line': '"$cmd" /d /s /v:off /c "${logical.skip(5).join(' ')}"',
        'logical_arguments': logical,
      });
      expect(proof['stdout_sha256'], sha256.convert(result.stdout).toString());
      expect(proof['stderr_sha256'], sha256.convert(result.stderr).toString());
    },
    skip: !Platform.isWindows
        ? 'Requires native Windows cmd and Job ownership.'
        : false,
  );
}
