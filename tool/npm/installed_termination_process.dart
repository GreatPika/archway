// Interactive observations retain original streams and independent cleanup owners.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../test/support/native_process_support.dart';
import '../../test/support/process_lifecycle.dart';
import '../../test/support/windows_job.dart';
import '../../test/support/windows_process.dart';
import '../../test/support/windows_process_pipes.dart';
import 'installed_assets.dart';

final class TerminationObservation {
  TerminationObservation(this.result, this.unconfirmed, this.helperTerminated);
  final NativeProcessResult? result;
  final Map<String, Object?>? unconfirmed;
  final bool helperTerminated;
}

Future<TerminationObservation> observeInstalledTermination(
  NpmInstalledControls controls,
  List<String> command, {
  required File ready,
  required ProcessSignal signal,
  required String route,
  required Duration readinessTimeout,
  required File evidence,
}) async {
  Process? child;
  WindowsSuspendedProcess? windowsChild;
  WindowsJob? job;
  WindowsProcessPipes? pipes;
  final owned = <String, WindowsOwnedProcess>{};
  final output = <int>[], errors = <int>[];
  final subscriptions = <StreamSubscription<List<int>>>[];
  final complete = <Future<void>>[];
  Future<int>? exit;
  int? code;
  Map<String, int>? pids;
  TerminationObservation? observation;
  Object? failure;
  StackTrace? failureStack;
  final cleanupFailures = <String>[];
  Map<String, Object>? windowsExecution;
  Future<void> clean(FutureOr<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stack) {
      cleanupFailures.add(error.toString());
      failure ??= error;
      failureStack ??= stack;
    }
  }

  void observe(Future<void> operation) {
    complete.add(
      operation.catchError((Object error, StackTrace stack) {
        failure ??= error;
        failureStack ??= stack;
      }),
    );
  }

  void capture(Stream<List<int>> stream, List<int> bytes) {
    final done = Completer<void>();
    subscriptions.add(
      stream.listen(
        bytes.addAll,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      ),
    );
    // Observe immediately, including failures while waiting for readiness.
    observe(done.future);
  }

  int? poll() => Platform.isWindows ? windowsChild?.exitCode : code;
  try {
    if (Platform.isWindows) {
      pipes = WindowsProcessPipes(
        onStdout: output.addAll,
        onStderr: errors.addAll,
      );
      job = WindowsJob();
      final windowsCommand = controls.recorder.windowsCommandFor?.call(command);
      windowsExecution = windowsCommand?.toJson();
      windowsChild = job.spawn(
        command,
        output: pipes,
        windowsCommand: windowsCommand,
        workingDirectory: controls.cwd.path,
        environment: controls.environment,
      );
    } else {
      child = await startPosixSession(
        command,
        workingDirectory: controls.cwd.path,
        environment: controls.environment,
      );
      capture(child.stdout, output);
      capture(child.stderr, errors);
      exit = child.exitCode.then((value) => code = value);
      observe(child.stdin.close());
    }
    final elapsed = Stopwatch()..start();
    while (!ready.existsSync() &&
        poll() == null &&
        elapsed.elapsed < readinessTimeout) {
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    controls.require(
      ready.existsSync(),
      'Installed core did not reach helper-ready barrier',
    );
    final value = jsonDecode(ready.readAsStringSync());
    controls.require(
      value is Map &&
          value.length == 2 &&
          value['helper'] is int &&
          value['core'] is int &&
          value['helper'] > 0 &&
          value['core'] > 0 &&
          value['helper'] != value['core'],
      'Invalid helper-ready process identities',
    );
    pids = (value as Map).cast<String, int>();
    if (route == 'native')
      controls.require(
        pids['core'] == (child?.pid ?? windowsChild!.pid),
        'Wrong direct-native reference process',
      );
    if (Platform.isWindows) {
      for (final entry in pids.entries)
        owned[entry.key] = WindowsOwnedProcess(entry.value);
      owned['core']!.terminate(23);
    } else if (route == 'group') {
      signalPosixSession(child!.pid, signal);
    } else {
      controls.require(child!.kill(signal), 'Cannot signal installed process');
    }
    try {
      if (Platform.isWindows) {
        final result = await pipes!.communicate(
          () => windowsChild!.exitCode,
          const Duration(seconds: 5),
        );
        code = result.exitCode;
      } else {
        await Future.wait<Object?>([
          exit!,
          ...complete,
        ], eagerError: true).timeout(const Duration(seconds: 5));
        if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
        final required = signal == ProcessSignal.sigint
            ? pids.values
            : [pids['core']!];
        if (required.any(isProcessAlive))
          throw TimeoutException('Core termination unconfirmed');
      }
      observation = TerminationObservation(
        (exitCode: code!, stdout: List.of(output), stderr: List.of(errors)),
        null,
        Platform.isWindows
            ? owned['helper']!.exited
            : !isProcessAlive(pids['helper']!),
      );
    } on TimeoutException {
      observation = TerminationObservation(null, {
        'outcome': 'termination-unconfirmed',
        'outer_exit': poll(),
        'core_pid_exists': Platform.isWindows
            ? !owned['core']!.exited
            : isProcessAlive(pids['core']!),
        'stdout_bytes': output.length,
        'stderr_bytes': errors.length,
      }, false);
    }
  } catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  } finally {
    // Every cleanup runs even if a prior owner fails; preserve the first failure.
    for (final handle in owned.values) await clean(handle.close);
    await clean(() => job?.close());
    await clean(() => windowsChild?.close());
    await clean(() => pipes?.close());
    if (child != null) {
      await clean(() => signalPosixGroup(child!.pid, ProcessSignal.sigkill));
      await clean(() async {
        child!.kill(ProcessSignal.sigkill);
        await exit!.timeout(const Duration(seconds: 5));
      });
      await clean(
        () => Future.wait(complete).timeout(const Duration(seconds: 5)),
      );
      for (final subscription in subscriptions)
        await clean(subscription.cancel);
    }
    await clean(() {
      File('${evidence.path}.stdout.log').writeAsBytesSync(output);
      File('${evidence.path}.stderr.log').writeAsBytesSync(errors);
      final report = {
        'command': command,
        'stdout_sha256': sha256.convert(output).toString(),
        'stderr_sha256': sha256.convert(errors).toString(),
        if (windowsExecution != null) 'windows_execution': windowsExecution,
        'route': route,
        'stimulus': Platform.isWindows
            ? 'TerminateProcess'
            : signal.toString().split('.').last,
        'exit': code,
        'pids': pids,
        'failure': failure?.toString(),
        'cleanup_failures': cleanupFailures,
        'observation': observation?.unconfirmed,
      };
      File('${evidence.path}.json')
          .writeAsStringSync('${jsonEncode(report)}\n');
    });
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return observation!;
}
