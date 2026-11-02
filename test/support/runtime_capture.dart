// Cross-platform bounded capture for developer lifecycle fixtures.
import 'dart:async';
import 'dart:io';

import 'windows_console.dart';
import 'windows_job.dart';
import 'windows_process.dart';
import 'windows_process_pipes.dart';

typedef _Captured = ({int code, List<int> out, List<int> err});
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// Each Windows launch belongs to an owned Job before its first instruction.
// POSIX retains the direct child and concurrently observes exit and both EOFs.
final class _Child {
  Process? _posix;
  WindowsJob? _job;
  WindowsSuspendedProcess? _windows;
  WindowsProcessPipes? _pipes;
  Future<_Captured>? _completion;
  bool _exited = false;
  final _out = <int>[], _err = <int>[];
  final _eofs = [Completer<void>(), Completer<void>()];
  final _subscriptions = <StreamSubscription<List<int>>>[];

  static Future<_Child> start(
    List<String> command, {
    required String cwd,
    required Map<String, String> environment,
    bool interruptible = false,
  }) async {
    final child = _Child();
    try {
      if (Platform.isWindows) {
        child._job = WindowsJob();
        child._pipes = WindowsProcessPipes();
        child._windows = interruptible
            ? startWindowsInterruptible(
                child._job!,
                command,
                workingDirectory: cwd,
                environment: environment,
                output: child._pipes,
              )
            : child._job!.spawn(
                command,
                workingDirectory: cwd,
                environment: environment,
                output: child._pipes,
              );
      } else {
        final process = child._posix = await Process.start(
          command.first,
          command.sublist(1),
          workingDirectory: cwd,
          environment: environment,
          includeParentEnvironment: false,
        );
        final completion = process.exitCode.then((code) {
          child._exited = true;
          return code;
        });
        child._completion =
            Future.wait<dynamic>([
              completion,
              ...child._eofs.map((done) => done.future),
            ], eagerError: true).then(
              (values) =>
                  (code: values[0] as int, out: child._out, err: child._err),
            );
        child._completion!.ignore();
        final streams = [process.stdout, process.stderr];
        final buffers = [child._out, child._err];
        for (var index = 0; index < streams.length; index++) {
          final done = child._eofs[index];
          child._subscriptions.add(
            streams[index].listen(
              buffers[index].addAll,
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              onError: (Object error, StackTrace stack) {
                if (!done.isCompleted) done.completeError(error, stack);
              },
            ),
          );
        }
        await process.stdin.close();
      }
      return child;
    } catch (_) {
      await child.close(operationFailed: true);
      rethrow;
    }
  }

  Future<_Captured> capture(Duration timeout) async {
    if (_pipes case final pipes?) {
      final result = await pipes.communicate(() => _windows!.exitCode, timeout);
      return (code: result.exitCode, out: result.stdout, err: result.stderr);
    }
    return _completion!.timeout(timeout);
  }

  Future<void> interrupt(String? sender) async {
    if (_windows case final target?) {
      await runWindowsConsoleSender([sender!, '${target.pid}']);
    } else {
      check(_posix!.kill(ProcessSignal.sigint), 'SIGINT delivery refused');
    }
  }

  Future<void> close({bool operationFailed = false}) async {
    if (Platform.isWindows) {
      finishWindowsConsoleCleanup([
        () => _job?.close(),
        () => _windows?.close(),
        () => _pipes?.close(),
      ], operationFailed: operationFailed);
    } else {
      Object? failure;
      StackTrace? trace;
      try {
        if (_posix != null && !_exited) {
          _posix!.kill(ProcessSignal.sigkill);
          await _posix!.exitCode.timeout(const Duration(seconds: 5));
        }
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      try {
        // Start both cancellations even when one throws; timeout does not own
        // these subscriptions, and direct-child exit does not imply pipe EOF.
        await Future.wait(
          _subscriptions.map((stream) async => await stream.cancel()),
        ).timeout(const Duration(seconds: 5));
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      } finally {
        for (final done in _eofs) {
          if (_completion != null && !done.isCompleted)
            done.completeError(StateError('Capture closed before EOF'));
        }
      }
      if (!operationFailed && failure != null)
        Error.throwWithStackTrace(failure, trace!);
    }
  }
}

Future<_Captured> capture(
  List<String> command, {
  required String cwd,
  required Map<String, String> environment,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final child = await _Child.start(command, cwd: cwd, environment: environment);
  var failed = false;
  try {
    return await child.capture(timeout);
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    await child.close(operationFailed: failed);
  }
}
