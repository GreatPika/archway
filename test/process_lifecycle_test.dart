import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/process_lifecycle.dart';

void main() {
  for (final operation in ['probe', 'cleanup']) {
    test('LifecycleSupportTest.test_cold_reaped_child_$operation', () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'test/support/process_lifecycle_cold.dart',
        operation,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      var exited = false;
      final completion = process.exitCode.then((value) {
        exited = true;
        return value;
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
    });
  }

  test(
    'LifecycleSupportTest.test_live_probe_does_not_terminate_process',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'test/support/process_fixture_child.dart',
      ]);
      final output = process.stdout.drain<void>();
      final errors = process.stderr.drain<void>();
      var exited = false;
      final completion = process.exitCode.then((value) {
        exited = true;
        return value;
      });
      try {
        expect(isProcessAlive(process.pid), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(exited, isFalse);
        terminateProcessId(process.pid);
        await completion.timeout(const Duration(seconds: 5));
        expect(isProcessAlive(process.pid), isFalse);
        terminateProcessId(process.pid);
      } finally {
        if (!exited) {
          process.kill(ProcessSignal.sigkill);
          await completion.timeout(const Duration(seconds: 5));
        }
        await Future.wait([output, errors]);
      }
    },
  );
}
