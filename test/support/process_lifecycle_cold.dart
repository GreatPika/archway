// Keep each operation's first failed native call in a fresh Dart process.
import 'dart:io';

import 'process_lifecycle.dart';

Future<void> main(List<String> arguments) async {
  final child = await Process.start(Platform.resolvedExecutable, ['--version']);
  final output = child.stdout.drain<void>();
  final errors = child.stderr.drain<void>();
  var exited = false;
  final completion = child.exitCode.then((value) {
    exited = true;
    return value;
  });
  final result = Future.wait<Object?>([completion, output, errors]);
  try {
    await result.timeout(const Duration(seconds: 5));
    // No lifecycle helper has run yet, and this child has already been reaped.
    switch (arguments.single) {
      case 'probe':
        if (isProcessAlive(child.pid)) {
          throw StateError('Reaped child ${child.pid} is still alive');
        }
      case 'cleanup':
        terminateProcessId(child.pid);
      default:
        throw ArgumentError.value(arguments.single, 'operation');
    }
  } finally {
    if (!exited) {
      child.kill(ProcessSignal.sigkill);
      await completion.timeout(const Duration(seconds: 5));
    }
    await result.timeout(const Duration(seconds: 5));
  }
}
