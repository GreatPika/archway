import 'package:test/test.dart';

import '../tool/installed_package_smoke.dart';

void main() {
  test('SDK batch template yields only its exact native target', () {
    const target = r'C:\owned café\bundle\bin\archway.exe';
    const script =
        '@ECHO OFF\nREM target_file_path_marker\n"$target" %*\nEXIT /B %ERRORLEVEL%\n';
    expect(sdkWindowsBundleTarget(script), target);
    expect(sdkWindowsBundleTarget(script.replaceAll('\n', '\r\n')), target);
    for (final bad in [
      script + 'echo extra\n',
      script + '\n',
      script.replaceFirst('REM', 'CALL'),
      script.replaceFirst(target, 'relative.exe'),
    ]) {
      expect(() => sdkWindowsBundleTarget(bad), throwsFormatException);
    }
  });
  test('owned SDK batch invocation uses raw cmd quoting, not CRT quoting', () {
    const cmd = r'C:\Windows\System32\cmd.exe';
    final args = [
      r'C:\installed café\archway.bat',
      '--root',
      r'D:\чужая папка\project',
      'init',
    ];
    final raw = sdkWindowsBatchCommand(args, cmd);
    expect(raw.applicationName, cmd);
    expect(
      raw.commandLine,
      '"$cmd" /d /s /v:off /c ""${args[0]}" "--root" "${args[2]}" "init""',
    );
    raw.validateFor(args);
  });
  test(
    'batch probe rejects shell syntax rather than encoding arbitrary input',
    () {
      for (final bad in [
        'a"b',
        'a%b',
        'a!b',
        'a&b',
        'a|b',
        'a<b',
        'a>b',
        'a^b',
        'a\nb',
        'a\rb',
      ]) {
        expect(
          () => sdkWindowsBatchCommand([
            r'C:\archway.bat',
            bad,
          ], r'C:\Windows\System32\cmd.exe'),
          throwsArgumentError,
        );
      }
    },
  );
}
