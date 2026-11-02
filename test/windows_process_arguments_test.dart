import 'package:test/test.dart';

import 'support/windows_process.dart';

void main() {
  test(
    'Windows process command line preserves empty, quoted and slash arguments',
    () {
      expect(
        windowsCommandLine(['tool.exe', '', 'plain', 'two words']),
        '"tool.exe" "" "plain" "two words"',
      );
      expect(
        windowsCommandLine(['a"b', r'C:\space path\']),
        '"a\\"b" "C:\\space path\\\\"',
      );
      expect(() => windowsCommandLine([]), throwsArgumentError);
      expect(() => windowsCommandLine(['bad\u0000name']), throwsArgumentError);
    },
  );
}
