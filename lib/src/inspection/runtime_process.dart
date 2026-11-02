import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

Map<String, dynamic> _cleanupDiagnostic() => {
  'code': 'RUNTIME_CLEANUP_UNCONFIRMED',
  'message':
      'Runtime termination could not be confirmed within 2 seconds; '
      'no further runtime or helper processes will be launched.',
  'path': null,
  'source_range': null,
};

class RuntimeFailure implements Exception {
  final Object _cause;
  final bool _cleanupUnconfirmed;
  RuntimeFailure(this._cause, this._cleanupUnconfirmed);
  Map<String, dynamic>? get cleanupDiagnostic =>
      _cleanupUnconfirmed ? _cleanupDiagnostic() : null;

  @override
  String toString() => _cause.toString();
}

class _CancellationWaiter {
  void Function()? callback;
  void deliver(void _) => callback?.call();
}

// One invocation owns this guard across all Dart project preflights. The
// optional launcher replaces only the OS boundary for owning-seam fault tests.
class RuntimeProcesses {
  // Do not let loader injection variables affect the external SDK preflight.
  // Retain NODE_ filtering for compatibility with previously prepared environments.
  Map<String, String> get environment => Map.fromEntries(
    Platform.environment.entries.where(
      (e) =>
          !e.key.toUpperCase().startsWith('NODE_') &&
          !e.key.toUpperCase().startsWith('LD_') &&
          !e.key.toUpperCase().startsWith('DYLD_'),
    ),
  );

  final Future<Process> Function(
    String,
    List<String>, {
    required String workingDirectory,
    required Map<String, String> environment,
  })?
  _startProcess;
  final Future<void>? _cancellation;
  bool _launchBlocked = false;
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  RuntimeProcesses(this._startProcess, Future<void>? signal)
    : _cancellation = signal?.then((_) {}, onError: (Object _) {}) {
    _cancellation?.then((_) {
      _cancelled = true;
    });
  }

  Future<List<int>> run(
    String executable,
    Map<String, String> environment,
    List<String> arguments,
    List<int> input, {
    required Duration timeout,
    required int stdoutLimit,
    required int stderrLimit,
    int? totalLimit,
  }) async {
    if (_launchBlocked) {
      throw const FormatException(
        'Previous runtime termination was not confirmed.',
      );
    }
    if (cancelled) throw const FormatException('Inspection cancelled.');
    final completed = Completer<List<int>>();
    final out = BytesBuilder(copy: false);
    var stdoutBytes = 0, stderrBytes = 0;
    var stdoutEnded = false, stderrEnded = false, inputEnded = false;
    var ending = false, spawnFailed = false, cleanupExpired = false;
    var terminationConfirmed = false;
    int? exit;
    Process? process;
    Future<void>? inputClose;
    final elapsed = Stopwatch()..start();
    StreamSubscription<List<int>>? stdoutSubscription, stderrSubscription;
    void fail(Object error) {
      if (!completed.isCompleted) completed.completeError(error);
    }

    void finish() {
      if (elapsed.elapsed >= timeout) {
        fail(const FormatException('Helper deadline exceeded.'));
        return;
      }
      if (exit != null &&
          stdoutEnded &&
          stderrEnded &&
          inputEnded &&
          !completed.isCompleted)
        completed.complete(out.takeBytes());
    }

    // Install handlers before any asynchronous completion. No error future is
    // left waiting for exit: a pipe/write failure itself starts cleanup.
    final timer = Timer(
      timeout,
      () => fail(const FormatException('Helper deadline exceeded.')),
    );
    final cancellationWaiter = _CancellationWaiter()
      ..callback = () => fail(const FormatException('Inspection cancelled.'));
    _cancellation?.then(cancellationWaiter.deliver);
    final spawning = Future<Process>.sync(() {
      if (_startProcess != null) {
        return _startProcess(
          executable,
          arguments,
          workingDirectory: p.dirname(executable),
          environment: environment,
        );
      }
      return Process.start(
        executable,
        arguments,
        workingDirectory: p.dirname(executable),
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      );
    });
    unawaited(
      spawning.then<void>(
        (current) {
          process = current;
          if (ending) {
            if (cleanupExpired) _stopLate(current);
            return;
          }
          try {
            stdoutSubscription = current.stdout.listen(
              (bytes) {
                stdoutBytes += bytes.length;
                if (stdoutBytes > stdoutLimit ||
                    totalLimit != null &&
                        stdoutBytes + stderrBytes > totalLimit) {
                  fail(const FormatException('Helper stdout limit exceeded.'));
                } else if (!completed.isCompleted) {
                  out.add(bytes);
                }
              },
              onError: fail,
              onDone: () {
                stdoutEnded = true;
                finish();
              },
            );
            stderrSubscription = current.stderr.listen(
              (bytes) {
                stderrBytes += bytes.length;
                if (stderrBytes > stderrLimit ||
                    totalLimit != null &&
                        stdoutBytes + stderrBytes > totalLimit) {
                  fail(const FormatException('Helper stderr limit exceeded.'));
                }
              },
              onError: fail,
              onDone: () {
                stderrEnded = true;
                finish();
              },
            );
            current.exitCode.then((code) {
              exit = code;
              if (code != 0)
                fail(FormatException('Helper exited with code $code.'));
              finish();
            }, onError: fail);
            Future<void>.sync(() async {
              current.stdin.add(input);
              await (inputClose = current.stdin.close());
            }).then((_) {
              inputEnded = true;
              finish();
            }, onError: fail);
          } catch (error) {
            fail(error);
          }
        },
        onError: (Object error) {
          spawnFailed = true;
          fail(error);
        },
      ),
    );
    try {
      return await completed.future;
    } catch (error) {
      ending = true;
      // A single additional budget includes pending spawn, kill, reap, and
      // releasing local streams. A failed spawn creates no process to reap.
      try {
        await Future<void>.sync(() async {
          Process current;
          try {
            current = process ?? await spawning;
          } catch (_) {
            if (spawnFailed) return;
            rethrow;
          }
          if (cleanupExpired) return;
          try {
            current.kill(ProcessSignal.sigkill);
          } catch (_) {}
          await current.exitCode;
          terminationConfirmed = true;
          try {
            await (inputClose ??= current.stdin.close());
          } catch (_) {}
          await Future.wait([
            if (stdoutSubscription != null) stdoutSubscription!.cancel(),
            if (stderrSubscription != null) stderrSubscription!.cancel(),
          ]);
        }).timeout(const Duration(seconds: 2));
      } catch (_) {
        cleanupExpired = true;
        _launchBlocked = !terminationConfirmed;
        // Do not keep a local subscription alive after a refused reap.
        if (process != null) _stopLate(process!);
        unawaited(
          stdoutSubscription?.cancel().catchError((Object _) {}) ??
              Future.value(),
        );
        unawaited(
          stderrSubscription?.cancel().catchError((Object _) {}) ??
              Future.value(),
        );
      }
      throw RuntimeFailure(error, _launchBlocked);
    } finally {
      ending = true;
      timer.cancel();
      cancellationWaiter.callback = null;
      out.clear();
    }
  }

  // This is best effort, not an extension of the cleanup budget and not a
  // process-tree guarantee. Even errors from a late process are observed.
  void _stopLate(Process process) {
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      unawaited(
        process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      );
    } catch (_) {}
    try {
      unawaited(process.exitCode.then<void>((_) {}, onError: (Object _) {}));
    } catch (_) {}
    for (final stream in [process.stdout, process.stderr]) {
      try {
        unawaited(
          stream
              .listen((_) {}, onError: (Object _) {})
              .cancel()
              .catchError((Object _) {}),
        );
      } catch (_) {}
    }
  }
}
