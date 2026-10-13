// Durable acceptance capture; POSIX ownership covers only the direct child.
import 'dart:async';
import 'dart:io';

import '../../test/support/windows_job.dart';
import '../../test/support/windows_process.dart';
import '../../test/support/windows_process_pipes.dart';

Future<int> captureAcceptanceProcess(
  List<String> command,
  String repository,
  Map<String, String> environment,
  RandomAccessFile stdout,
  RandomAccessFile stderr,
  Duration timeout,
) async {
  void write(RandomAccessFile file, List<int> bytes) {
    file.writeFromSync(bytes);
    file.flushSync();
  }

  if (Platform.isWindows) {
    WindowsProcessPipes? pipes;
    WindowsJob? job;
    WindowsSuspendedProcess? child;
    try {
      pipes = WindowsProcessPipes(
        onStdout: (bytes) => write(stdout, bytes),
        onStderr: (bytes) => write(stderr, bytes),
        retainOutput: false,
      );
      job = WindowsJob();
      child = job.spawn(
        command,
        output: pipes,
        workingDirectory: repository,
        environment: environment,
      );
      return (await pipes.communicate(() => child!.exitCode, timeout)).exitCode;
    } finally {
      try {
        job?.close();
      } finally {
        try {
          child?.close();
        } finally {
          pipes?.close();
        }
      }
    }
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
