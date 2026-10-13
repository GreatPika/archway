// Build provenance for clean tracked sources and the actual assembler runtime.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<Map<String, Object>> sourceIdentity(
  Directory repo, {
  Map<String, String>? environment,
}) async {
  Future<String> git(List<String> arguments) async {
    final command = ['-C', repo.path, ...arguments];
    final result = await Process.run(
      'git',
      command,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        command,
        '${result.stderr}',
        result.exitCode,
      );
    }
    return (result.stdout as String).trim();
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
  final child = await Process.start(executable, [
    '--version',
  ], workingDirectory: cwd.path);
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
    ]).timeout(const Duration(seconds: 30));
    final code = results.first as int;
    if (code != 0) {
      throw ProcessException(
        executable,
        ['--version'],
        utf8.decode(errors, allowMalformed: true),
        code,
      );
    }
    // Python text-mode capture normalizes each stream before concatenation.
    String text(List<int> bytes) =>
        utf8.decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return (text(output) + text(errors)).trim();
  } finally {
    try {
      if (!exited) {
        child.kill(ProcessSignal.sigkill);
        await exit.timeout(const Duration(seconds: 5));
      }
    } finally {
      await out.cancel();
      await err.cancel();
    }
  }
}
