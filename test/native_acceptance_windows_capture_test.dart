import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/windows_job.dart';
import 'support/windows_process.dart';
import 'support/windows_process_pipes.dart';

void main() {
  test(
    'Windows pipe sinks preserve default buffering and allow no-buffer capture',
    () async {
      final temp = Directory.systemTemp.createTempSync('acceptance-pipes-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'child.dart'))
        ..writeAsStringSync("""
import 'dart:io';
Future<void> main() async {
 stdout.add(List<int>.filled(100000, 97));
 stderr.add(List<int>.filled(70000, 98));
 await stdout.flush(); await stderr.flush();
}
""");
      for (final retain in [true, false]) {
        final output = <int>[], errors = <int>[];
        final pipes = retain
            ? WindowsProcessPipes(
                onStdout: output.addAll,
                onStderr: errors.addAll,
              )
            : WindowsProcessPipes(
                onStdout: output.addAll,
                onStderr: errors.addAll,
                retainOutput: false,
              );
        WindowsJob? job;
        WindowsSuspendedProcess? child;
        try {
          job = WindowsJob();
          child = job.spawn([
            Platform.resolvedExecutable,
            script.path,
          ], output: pipes);
          final result = await pipes.communicate(
            () => child!.exitCode,
            const Duration(seconds: 30),
          );
          expect(result.exitCode, 0);
          expect(output, List<int>.filled(100000, 97));
          expect(errors, List<int>.filled(70000, 98));
          expect(result.stdout, retain ? output : isEmpty);
          expect(result.stderr, retain ? errors : isEmpty);
        } finally {
          try {
            job?.close();
          } finally {
            try {
              child?.close();
            } finally {
              pipes.close();
            }
          }
        }
      }
    },
    skip: !Platform.isWindows ? 'Native Windows pipe control.' : false,
  );
}
