// Bounded raw process capture for developer fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef _Captured = ({int code, List<int> out, List<int> err});
Future<_Captured> capture(
  String program,
  List<String> arguments, {
  String input = '',
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? environment,
}) async {
  final child = await Process.start(
    program,
    arguments,
    environment: environment ?? Platform.environment,
    includeParentEnvironment: false,
  );
  final out = <int>[], err = <int>[];
  final eofs = [Completer<void>(), Completer<void>()];
  final subscriptions = <StreamSubscription<List<int>>>[];
  var exited = false, failed = false;
  final completion = Future.wait<Object?>([
    child.exitCode.then((code) {
      exited = true;
      return code;
    }),
    ...eofs.map((done) => done.future),
    () async {
      child.stdin.add(utf8.encode(input));
      await child.stdin.close();
    }(),
  ], eagerError: true);
  completion.ignore();
  try {
    final streams = [child.stdout, child.stderr];
    final buffers = [out, err];
    for (var index = 0; index < streams.length; index++) {
      final done = eofs[index];
      subscriptions.add(
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
    final results = await completion.timeout(timeout);
    return (code: results.first as int, out: out, err: err);
  } on TimeoutException {
    failed = true;
    throw TimeoutException('$arguments timed out; stdout=$out; stderr=$err');
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    Object? failure;
    StackTrace? trace;
    try {
      if (!exited) {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 2));
      }
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      // A deadline and direct-child exit do not dispose descendant-held pipes.
      // Start both cancellations even if one fails.
      await Future.wait(
        subscriptions.map((stream) async => await stream.cancel()),
      ).timeout(const Duration(seconds: 2));
    } catch (error, stack) {
      failure ??= error;
      trace ??= stack;
    } finally {
      for (final done in eofs) {
        if (!done.isCompleted)
          done.completeError(StateError('Capture closed before EOF'));
      }
    }
    if (!failed && failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
