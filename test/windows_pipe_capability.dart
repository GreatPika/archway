// Native Windows output, EOF, timeout and restricted-inheritance controls.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'support/windows_job.dart';
import 'support/windows_process.dart';
import 'support/windows_process_pipes.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  final api = DynamicLibrary.open('kernel32.dll');
  final event = api
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Int32, Int32, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Void>)
      >('CreateEventW');
  final wait = api
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  final close = api
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final artifacts = Directory.systemTemp.createTempSync('archway-pipe-writer-');
  final attributes = calloc<Uint8>(24);
  Pointer<Void> sentinel = nullptr;
  try {
    final writer = '${artifacts.path}\\writer.exe';
    final invalid = File('${artifacts.path}\\invalid.dart')
      ..writeAsStringSync('void main( {');
    for (final source in [
      invalid.path,
      'test/support/windows_pipe_child.dart',
    ]) {
      final expectedFailure = source == invalid.path;
      final destination = expectedFailure
          ? '${artifacts.path}\\invalid.exe'
          : writer;
      WindowsProcessPipes? capture;
      WindowsJob? compilerJob;
      WindowsSuspendedProcess? compiler;
      try {
        capture = WindowsProcessPipes();
        compilerJob = WindowsJob();
        compiler = compilerJob.spawn([
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'compile',
          'exe',
          source,
          '-o',
          destination,
        ], output: capture);
        final result = await capture.communicate(
          () => compiler!.exitCode,
          const Duration(seconds: 60),
        );
        if (expectedFailure) {
          check(
            result.exitCode != 0 &&
                result.stderr.isNotEmpty &&
                !File(destination).existsSync(),
            'Invalid AOT preparation falsely succeeded',
          );
        } else {
          check(
            result.exitCode == 0,
            'AOT pipe fixture compilation failed: ${utf8.decode(result.stderr, allowMalformed: true)}',
          );
        }
      } on WindowsPipeTimeout catch (error) {
        throw StateError(
          'AOT preparation timed out; stdout=${utf8.decode(error.stdout, allowMalformed: true)}; stderr=${utf8.decode(error.stderr, allowMalformed: true)}',
        );
      } finally {
        try {
          compilerJob?.close();
        } finally {
          try {
            compiler?.close();
          } finally {
            capture?.close();
          }
        }
      }
    }
    attributes.cast<Uint32>().value = 24;
    (attributes + 16).cast<Int32>().value =
        1; // Deliberately inheritable, unlisted.
    sentinel = event(attributes.cast(), 1, 0, nullptr);
    check(sentinel != nullptr, 'Failed to create inheritance sentinel');
    for (final mode in ['payload', 'timeout', 'late']) {
      final root = Directory.systemTemp.createTempSync('archway-pipe-');
      WindowsProcessPipes? pipes;
      WindowsJob? job;
      WindowsSuspendedProcess? process;
      try {
        pipes = WindowsProcessPipes();
        job = WindowsJob();
        final ready = File('${root.path}\\ready');
        process = job.spawn([
          writer,
          mode,
          mode == 'payload' ? '${sentinel.address}' : ready.path,
        ], output: pipes);
        if (mode == 'timeout' || mode == 'late') {
          final barrier = mode == 'late'
              ? File('${ready.path}.parent-exited')
              : ready;
          final elapsed = Stopwatch()..start();
          while (!barrier.existsSync()) {
            check(
              elapsed.elapsed < const Duration(seconds: 10),
              'Writer did not become ready',
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          if (mode == 'late')
            check(process.exitCode == 0, 'Parent has not exited');
          var timedOut = false;
          try {
            await pipes.communicate(
              () => process!.exitCode,
              const Duration(milliseconds: 50),
            );
          } on WindowsPipeTimeout catch (error) {
            timedOut = true;
            check(
              utf8.decode(error.stdout) == (mode == 'late' ? '' : 'out') &&
                  utf8.decode(error.stderr) == (mode == 'late' ? '' : 'err'),
              'Timeout did not preserve partial raw output',
            );
          }
          check(
            timedOut,
            'Capture completed before both writer handles closed',
          );
          if (mode == 'late') {
            File('${ready.path}.release').createSync();
          } else {
            job.close();
          }
        }
        final result = await pipes.communicate(
          () => process!.exitCode,
          const Duration(seconds: 10),
        );
        check(
          result.exitCode == (mode == 'timeout' ? 1 : 0),
          'Wrong captured exit code',
        );
        if (mode == 'payload') {
          check(
            result.stdout.length == 100000 &&
                result.stderr.length == 70000 &&
                result.stdout.every((byte) => byte == 97) &&
                result.stderr.every((byte) => byte == 98),
            'Large dual-stream output did not roundtrip',
          );
          check(
            wait(sentinel, 0) == 258,
            'An unlisted inheritable handle leaked to child',
          );
        } else {
          check(
            utf8.decode(result.stdout) == 'out' &&
                utf8.decode(result.stderr) == 'err',
            'Lost output across parent exit or capture timeout',
          );
        }
        stdout.writeln('Windows native pipe $mode passed');
      } finally {
        try {
          job?.close();
        } finally {
          try {
            process?.close();
          } finally {
            try {
              pipes?.close();
            } finally {
              root.deleteSync(recursive: true);
            }
          }
        }
      }
    }
  } finally {
    calloc.free(attributes);
    try {
      if (sentinel != nullptr)
        check(close(sentinel) != 0, 'Sentinel close failed');
    } finally {
      artifacts.deleteSync(recursive: true);
    }
  }
}
