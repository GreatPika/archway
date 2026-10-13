import 'dart:convert';

import 'package:test/test.dart';

import 'support/native_process_support.dart';

void main() {
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
