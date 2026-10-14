import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_process_pipes.dart';

void main() {
  if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
    test('native pipes reject unsupported hosts', () {
      expect(() => WindowsProcessPipes(), throwsUnsupportedError);
    });
    return; // A rejected host does not establish Windows startup capability.
  }
  for (var attempt = 1; attempt <= 5; attempt++) {
    test(
      'native pipe startup installs handles with cold and warm size probes ($attempt)',
      () async {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--suppress-analytics',
          'run',
          'test/support/windows_process_pipes_cold.dart',
        ]);
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        var exited = false;
        final completion = process.exitCode.then((code) {
          exited = true;
          return code;
        });
        final result = Future.wait<Object>([completion, output, errors]);
        try {
          final values = await result.timeout(const Duration(seconds: 15));
          expect(values[0], 0, reason: '${values[1]}\n${values[2]}');
          expect(values[1], isEmpty);
          expect(values[2], isEmpty);
        } finally {
          if (!exited) {
            process.kill(ProcessSignal.sigkill);
            await completion.timeout(const Duration(seconds: 5));
          }
          await result.timeout(const Duration(seconds: 5));
        }
      },
    );
  }
}
