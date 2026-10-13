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
        expect(command, [
          executable,
          '-latest',
          '-products',
          '*',
          '-requires',
          'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
          '-property',
          'installationPath',
          '-utf8',
        ]);
        expect(timeout, const Duration(seconds: 15));
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
