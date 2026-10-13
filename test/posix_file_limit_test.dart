import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  test(
    'file-limit child keeps its PID and survives a real partial write',
    () async {
      final root = Directory.systemTemp.createTempSync('archway-file-limit-');
      final output = File('${root.path}/partial café');
      try {
        final child = await Process.start(
          Platform.resolvedExecutable,
          [
            File('test/support/posix_file_limit_child.dart').absolute.path,
            '/bin/sh',
            '-c',
            'printf "%s\\n" "\$\$"; printf abc > "\$1"; '
                'code=\$?; printf "survived:%s\\n" "\$code"; exit "\$code"',
            'fixture',
            output.path,
          ],
          environment: {'PATH': '/no-runtime-here'},
        );
        final completion = Future.wait<Object?>([
          child.exitCode,
          child.stdout.transform(utf8.decoder).join(),
          child.stderr.transform(utf8.decoder).join(),
          child.stdin.close(),
        ]);
        try {
          final result = await completion.timeout(const Duration(seconds: 10));
          final code = result[0] as int;
          expect(
            code,
            greaterThan(0),
            reason: 'Expected write failure, not a signal',
          );
          expect(result[1], '${child.pid}\nsurvived:$code\n');
          expect(result[2], isNotEmpty);
          expect(output.readAsBytesSync(), [97]);
        } finally {
          child.kill(ProcessSignal.sigkill);
          await completion.timeout(const Duration(seconds: 2));
        }
        output.writeAsStringSync('parent is unlimited');
        expect(output.readAsStringSync(), 'parent is unlimited');
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
