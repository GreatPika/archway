// Build provenance for clean tracked sources and the actual assembler runtime.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<Map<String, Object>> sourceIdentity(
  Directory repo, {
  Map<String, String>? environment,
  Duration gitTimeout = const Duration(seconds: 30),
}) async {
  // Tooling tests may tighten this budget, but callers cannot extend it.
  if (gitTimeout <= Duration.zero || gitTimeout > const Duration(seconds: 30)) {
    throw ArgumentError.value(
      gitTimeout,
      'gitTimeout',
      'must be > 0 and <= 30s',
    );
  }
  // Git environment controls can redirect -C or replace repository config.
  // Copy the selected environment rather than merging ambient variables back in.
  final gitEnvironment = Map<String, String>.from(
    environment ?? Platform.environment,
  )..removeWhere((key, _) => key.toUpperCase().startsWith('GIT_'));
  Future<String> git(List<String> arguments) async {
    final command = ['-C', repo.path, ...arguments];
    final (output, _) = await _capture(
      'git',
      command,
      environment: gitEnvironment,
      timeout: gitTimeout,
    );
    return utf8.decode(output).trim();
  }

  if ((await git(['status', '--porcelain', '--untracked-files=no']))
      .isNotEmpty) {
    throw StateError('Artifact export requires clean tracked sources');
  }
  return {
    'commit': await git(['rev-parse', 'HEAD']),
    'tree': await git(['rev-parse', 'HEAD^{tree}']),
    'lockfile_sha256': {
      for (final name in [
        'pubspec.lock',
        'assets/typescript/package-lock.json',
      ])
        name:
            (await sha256.bind(File(p.join(repo.path, name)).openRead()).first)
                .toString(),
    },
  };
}

/// Observe --version from the same cwd used by the assembler, including PATH.
Future<String> runtimeVersion(String executable, Directory cwd) async {
  final (output, errors) = await _capture(executable, [
    '--version',
  ], workingDirectory: cwd.path);
  // Python text-mode capture normalizes each stream before concatenation.
  String text(List<int> bytes) =>
      utf8.decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return (text(output) + text(errors)).trim();
}

// Bounded capture and direct-child cleanup only, not process-tree termination.
Future<(List<int>, List<int>)> _capture(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final child = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: environment == null,
  );
  final output = <int>[], errors = <int>[];
  final outputDone = Completer<void>(), errorsDone = Completer<void>();
  final out = child.stdout.listen(
    output.addAll,
    onDone: outputDone.complete,
    onError: outputDone.completeError,
  );
  final err = child.stderr.listen(
    errors.addAll,
    onDone: errorsDone.complete,
    onError: errorsDone.completeError,
  );
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final results = await Future.wait<Object?>([
      exit,
      child.stdin.close(),
      outputDone.future,
      errorsDone.future,
    ]).timeout(timeout);
    final code = results.first as int;
    if (code != 0) {
      throw ProcessException(
        executable,
        arguments,
        utf8.decode(errors, allowMalformed: true),
        code,
      );
    }
    return (output, errors);
  } finally {
    try {
      if (!exited) child.kill(ProcessSignal.sigkill);
    } finally {
      // Start pipe disposal even if direct-child exit never resolves. A timeout
      // stops waiting; it does not cancel an async function suspended on exit.
      await Future.wait([if (!exited) exit, out.cancel(), err.cancel()])
          .timeout(const Duration(seconds: 5));
    }
  }
}
