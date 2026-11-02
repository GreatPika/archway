import 'dart:convert';
import 'dart:async';
import 'dart:io';

import '../tool/ci/prepare_windows_process_support.dart';

import 'package:test/test.dart';

import 'support/native_process_support.dart';

void main() {
  test('compiler bootstrap times out and reaps a hanging child', () async {
    final root = Directory.systemTemp.createTempSync('bootstrap-timeout-');
    addTearDown(() => root.deleteSync(recursive: true));
    final script = File('${root.path}/child.dart')
      ..writeAsStringSync(
        "import 'dart:async'; void main() { Timer.periodic(Duration(seconds: 1), (_) {}); }",
      );
    await expectLater(
      bootstrapRun([
        Platform.resolvedExecutable,
        script.path,
      ], timeout: const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'compiler bootstrap captures streams and rejects a failed command',
    () async {
      final root = Directory.systemTemp.createTempSync('bootstrap-run-');
      addTearDown(() => root.deleteSync(recursive: true));
      final script = File('${root.path}/child.dart')
        ..writeAsStringSync(
          "import 'dart:io'; void main(List<String> args) { "
          "stdout.write('out'); stderr.write('err'); exitCode=int.parse(args.single); }",
        );
      final result = await bootstrapRun([
        Platform.resolvedExecutable,
        script.path,
        '0',
      ]);
      expect(result.exitCode, 0);
      expect(utf8.decode(result.stdout), 'out');
      expect(utf8.decode(result.stderr), 'err');
      await expectLater(
        bootstrapRun([Platform.resolvedExecutable, script.path, '7']),
        throwsA(isA<ProcessException>().having((e) => e.errorCode, 'exit', 7)),
      );
    },
  );

  test('vswhere requests UTF-8 and preserves a non-ASCII installation path', () async {
    const executable =
        r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';
    const installation = r'C:\Outils café\Visual Studio 東京';
    final result = await visualStudioInstallation(
      executable,
      run: (command, {required timeout}) async {
        expect(command.first, executable);
        expect(command, hasLength(9));
        expect(command, containsAll(['-latest', '-utf8']));
        for (final [flag, value] in const [
          ['-products', '*'],
          ['-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'],
          ['-property', 'installationPath'],
        ]) {
          final index = command.indexOf(flag);
          expect(index, inInclusiveRange(1, command.length - 2));
          expect(command[index + 1], value);
        }
        return (
          exitCode: 0,
          stdout: utf8.encode('$installation\r\n'),
          stderr: <int>[],
        );
      },
    );
    expect(result, installation);
  });
}
