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

  if (!Platform.isWindows) {
    test(
      'owned POSIX session keeps the executable PID and group signal exit',
      () async {
        final process = await startPosixSession(
          ['/bin/sh', '-c', r'printf "%s\n" "$$"; exec /bin/sleep 60'],
          workingDirectory: Directory.current.path,
          environment: Platform.environment,
        );
        final errors = process.stderr.drain<void>();
        try {
          final firstLine = await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 15));
          expect(int.parse(firstLine), process.pid);
          signalPosixSession(process.pid, ProcessSignal.sigterm);
          expect(
            await process.exitCode.timeout(const Duration(seconds: 5)),
            -15,
          );
          expect(isProcessAlive(process.pid), isFalse);
        } finally {
          process.kill(ProcessSignal.sigkill);
          try {
            await process.exitCode.timeout(const Duration(seconds: 5));
          } finally {
            await errors.timeout(const Duration(seconds: 5));
          }
        }
      },
    );
  }

  test(
    'owned Windows handle preserves exit 23 after direct-child reap',
    () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'test/support/process_fixture_child.dart',
      ]);
      final output = child.stdout.drain<void>(),
          errors = child.stderr.drain<void>();
      WindowsOwnedProcess? owned;
      try {
        owned = WindowsOwnedProcess(child.pid);
        expect(owned.exited, isFalse);
        owned.terminate(23);
        expect(await child.exitCode.timeout(const Duration(seconds: 5)), 23);
        expect(owned.exited, isTrue);
      } finally {
        try {
          owned?.close();
        } finally {
          child.kill();
          try {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } finally {
            await Future.wait([output, errors])
                .timeout(const Duration(seconds: 5));
          }
        }
      }
    },
    skip: !Platform.isWindows
        ? 'Requires native Windows owned process handles.'
        : false,
  );

  // Windows real console delivery is covered by windows_console_capability.dart.
  if (!Platform.isWindows) {
    test('LifecycleSupportTest.test_real_ctrl_c_reports_and_exits', () async {
      final directory = Directory.systemTemp.createTempSync('archway-sigint-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final marker = File('${directory.path}/ready');
      final process = await Process.start(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'test/support/process_fixture_child.dart',
        '--sigint-exit-23',
        marker.path,
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
        final readiness = Stopwatch()..start();
        while (!marker.existsSync() &&
            !exited &&
            readiness.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(marker.existsSync(), isTrue, reason: 'SIGINT handler not ready');
        expect(isProcessAlive(process.pid), isTrue);
        expect(process.kill(ProcessSignal.sigint), isTrue);
        final values = await result.timeout(const Duration(seconds: 10));
        expect(values[0], 23, reason: '${values[1]}\n${values[2]}');
        expect(values[1], isEmpty);
        expect(values[2], isEmpty);
        expect(isProcessAlive(process.pid), isFalse);
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
