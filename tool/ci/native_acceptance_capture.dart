// Durable acceptance capture; POSIX ownership covers only the direct child.
import 'dart:async';
import 'dart:io';

import '../../test/support/windows_job.dart';
import '../../test/support/windows_command.dart';
import '../../test/support/windows_process.dart';
import '../../test/support/windows_process_pipes.dart';

/// The same monotonic operation budget gates startup and successful completion.
Duration windowsCaptureRemaining(Duration timeout, Duration elapsed) {
  if (elapsed >= timeout)
    throw TimeoutException('Acceptance deadline', timeout);
  return timeout - elapsed;
}

/// Narrow Windows owner boundary shared by native capture and failure controls.
Future<int> captureWithWindowsOwners({
  required Future<int> Function() capture,
  required void Function() closeJob,
  required void Function() closeChild,
  required void Function() closePipes,
  void Function(Object, StackTrace)? reportCleanupFailure,
}) async {
  Object? failure;
  StackTrace? failureStack;
  int? code;
  void close(void Function() closer) {
    try {
      closer();
    } catch (error, stack) {
      if (failure == null) {
        failure = error;
        failureStack = stack;
      } else {
        try {
          if (reportCleanupFailure != null) {
            reportCleanupFailure(error, stack);
          } else {
            // This is the invoking process's stderr, never a child log handle.
            stderr.writeln(
              'Windows acceptance cleanup unconfirmed: $error\n$stack',
            );
          }
        } catch (_) {
          // A broken diagnostic sink must not replace the first failure.
        }
      }
    }
  }

  try {
    code = await capture();
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  } finally {
    close(closeJob);
    close(closeChild);
    close(closePipes);
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return code!;
}

Future<int> captureAcceptanceProcess(
  List<String> command,
  String repository,
  Map<String, String> environment,
  RandomAccessFile stdout,
  RandomAccessFile stderr,
  Duration timeout, {
  File? windowsStdinFile,
  bool waitForWindowsJobEmpty = false,
  WindowsRawCommandLine? windowsCommand,
}) async {
  windowsCommand?.validateFor(command);
  final windowsElapsed = waitForWindowsJobEmpty ? (Stopwatch()..start()) : null;
  if ((windowsStdinFile != null ||
          waitForWindowsJobEmpty ||
          windowsCommand != null) &&
      !Platform.isWindows) {
    throw UnsupportedError('Windows capture options require native Windows');
  }
  void write(RandomAccessFile file, List<int> bytes) {
    file.writeFromSync(bytes);
    file.flushSync();
  }

  if (Platform.isWindows) {
    WindowsProcessPipes? pipes;
    WindowsJob? job;
    WindowsSuspendedProcess? child;
    return captureWithWindowsOwners(
      capture: () async {
        pipes = WindowsProcessPipes(
          onStdout: (bytes) => write(stdout, bytes),
          onStderr: (bytes) => write(stderr, bytes),
          retainOutput: false,
          stdinFile: windowsStdinFile,
        );
        job = WindowsJob();
        child = job!.spawn(
          command,
          windowsCommand: windowsCommand,
          output: pipes,
          workingDirectory: repository,
          environment: environment,
        );
        final result = await pipes!.communicate(
          () {
            final code = child!.exitCode;
            if (code == null ||
                (waitForWindowsJobEmpty && job!.activeProcessCount != 0)) {
              return null;
            }
            return code;
          },
          windowsElapsed == null
              ? timeout
              : windowsCaptureRemaining(timeout, windowsElapsed.elapsed),
        );
        if (windowsElapsed != null)
          windowsCaptureRemaining(timeout, windowsElapsed.elapsed);
        return result.exitCode;
      },
      closeJob: () => job?.close(),
      closeChild: () => child?.close(),
      closePipes: () => pipes?.close(),
    );
  }

  final elapsed = Stopwatch()..start();
  final spawning = Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: repository,
    environment: environment,
    includeParentEnvironment: false,
  );
  final Process child;
  try {
    child = await spawning.timeout(timeout);
  } catch (_) {
    // A late spawn still owns a direct child; observe every cleanup error.
    unawaited(
      spawning
          .then((late) async {
            late.kill(ProcessSignal.sigkill);
            await late.exitCode.timeout(const Duration(seconds: 5));
            await late.stdout.drain<void>().timeout(const Duration(seconds: 5));
            await late.stderr.drain<void>().timeout(const Duration(seconds: 5));
          })
          .catchError((Object _) {}),
    );
    rethrow;
  }
  final outDone = Completer<void>(), errDone = Completer<void>();
  StreamSubscription<List<int>> capture(
    Stream<List<int>> stream,
    RandomAccessFile file,
    Completer<void> done,
  ) => stream.listen(
    (bytes) {
      try {
        write(file, bytes);
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  final out = capture(child.stdout, stdout, outDone);
  final err = capture(child.stderr, stderr, errDone);
  var exited = false;
  final completion = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final remaining = timeout - elapsed.elapsed;
    final results = await Future.wait<Object?>(
      [completion, child.stdin.close(), outDone.future, errDone.future],
      eagerError: true,
    ).timeout(remaining.isNegative ? Duration.zero : remaining);
    if (elapsed.elapsed >= timeout)
      throw TimeoutException('Acceptance deadline', timeout);
    return results.first as int;
  } finally {
    try {
      if (!exited) {
        child.kill(ProcessSignal.sigkill);
        await completion.timeout(const Duration(seconds: 5));
      }
    } finally {
      try {
        await out.cancel().timeout(const Duration(seconds: 5));
      } finally {
        await err.cancel().timeout(const Duration(seconds: 5));
      }
    }
  }
}
