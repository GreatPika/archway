// Explicit preparation of owned test support with the pinned installed compiler.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../test/support/native_process_support.dart';

Future<NativeProcessResult> bootstrapRun(
  List<String> command, {
  Duration timeout = const Duration(seconds: 60),
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  // This bootstrap must not depend on the process bridge it is compiling.
  final child = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: environment == null,
  );
  final output = <int>[], errors = <int>[];
  final out = child.stdout.listen(output.addAll);
  final err = child.stderr.listen(errors.addAll);
  final outputDone = out.asFuture<void>();
  final errorDone = err.asFuture<void>();
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final values = await Future.wait<Object?>([
      exit,
      outputDone,
      errorDone,
      child.stdin.close(),
    ]).timeout(timeout);
    final result = (exitCode: values[0] as int, stdout: output, stderr: errors);
    if (result.exitCode != 0) {
      throw ProcessException(
        command.first,
        command.skip(1).toList(),
        utf8.decode(result.stderr, allowMalformed: true),
        result.exitCode,
      );
    }
    return result;
  } finally {
    try {
      if (!exited) {
        // Bootstrap owns the direct compiler process only; the suspended
        // process/Job bridge being built is not available yet.
        child.kill(ProcessSignal.sigkill);
        await exit.timeout(const Duration(seconds: 5));
      }
    } finally {
      // A descendant may retain inherited streams even after direct-child exit.
      await out.cancel();
      await err.cancel();
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) throw ArgumentError('No arguments expected');
  if (!Platform.isWindows) return;
  final root = File.fromUri(Platform.script).parent.parent.parent;
  final output = Directory.fromUri(root.uri.resolve('build/windows-process/'))
    ..createSync(recursive: true);
  await buildNativeLibrary(
    File.fromUri(root.uri.resolve('test/support/windows_process_bridge.c')),
    File.fromUri(output.uri.resolve('archway_process.dll')),
    run: bootstrapRun,
  );
  stdout.writeln('Prepared developer-only Windows process error capture.');
}
