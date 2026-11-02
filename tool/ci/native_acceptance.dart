// Native acceptance building blocks. Full source-gate integration is separate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'native_acceptance_capture.dart';
import '../../test/support/windows_command.dart';

const suiteTimeout = Duration(seconds: 600);

final class SuiteExitFailure implements Exception {
  SuiteExitFailure(this.proof);
  final Map<String, Object?> proof;
  @override
  String toString() =>
      'Native acceptance suite ${proof['suite']} failed with exit ${proof['exit_code']}';
}

Future<Map<String, Object?>> executeSuite(
  String name,
  List<String> command,
  String repository,
  Map<String, String> environment,
  Directory output, {
  Duration timeout = suiteTimeout,
  void Function(Map<String, Object?> proof)? onProof,
  File? windowsStdinFile,
  bool waitForWindowsJobEmpty = false,
  WindowsRawCommandLine? windowsCommand,
}) async {
  windowsCommand?.validateFor(command);
  if (windowsCommand != null && !Platform.isWindows) {
    throw UnsupportedError('Raw Windows commands require native Windows');
  }
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name) ||
      command.isEmpty ||
      timeout <= Duration.zero) {
    throw ArgumentError('Expected suite name, command and positive timeout');
  }
  final files = [
    for (final suffix in ['stdout.log', 'stderr.log', 'json'])
      File(p.join(output.path, '$name.$suffix')),
  ];
  // Reserve every evidence name before launching; no prior evidence is replaced.
  for (final file in files) {
    file.createSync(exclusive: true);
  }
  final out = files[0].openSync(mode: FileMode.writeOnly);
  RandomAccessFile? err;
  final elapsed = Stopwatch()..start();
  int? code;
  var timedOut = false;
  Object? failure;
  StackTrace? stack;
  try {
    err = files[1].openSync(mode: FileMode.writeOnly);
    code = await captureAcceptanceProcess(
      command,
      repository,
      environment,
      out,
      err,
      timeout,
      windowsCommand: windowsCommand,
      windowsStdinFile: windowsStdinFile,
      waitForWindowsJobEmpty: waitForWindowsJobEmpty,
    );
  } catch (error, trace) {
    timedOut = error is TimeoutException;
    failure = error;
    stack = trace;
  } finally {
    try {
      out.closeSync();
    } finally {
      err?.closeSync();
    }
  }
  final proof = <String, Object?>{
    'suite': name,
    'command': command,
    if (windowsCommand != null) 'windows_execution': windowsCommand.toJson(),
    'exit_code': code,
    'timed_out': timedOut,
    'elapsed_seconds': (elapsed.elapsedMicroseconds / 1000).round() / 1000,
    'timeout_seconds': timeout.inMicroseconds / Duration.microsecondsPerSecond,
    'stdout': p.basename(files[0].path),
    'stderr': p.basename(files[1].path),
    'stdout_sha256': (await sha256.bind(files[0].openRead()).first).toString(),
    'stderr_sha256': (await sha256.bind(files[1].openRead()).first).toString(),
  };
  // Preserve integer seconds in the established production receipt contract.
  if (timeout.inMicroseconds % Duration.microsecondsPerSecond == 0)
    proof['timeout_seconds'] = timeout.inSeconds;
  files[2].writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(proof)}\n',
    flush: true,
  );
  onProof?.call(proof);
  if (failure != null) Error.throwWithStackTrace(failure, stack!);
  if (code != 0) throw SuiteExitFailure(proof);
  return proof;
}
