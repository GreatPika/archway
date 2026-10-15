import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_acceptance.dart';
import 'release_execution_receipts.dart';

/// Sequential installer evidence with owned Windows job completion.
final class InstallerCommandRecorder {
  InstallerCommandRecorder({
    required this.output,
    required this.prefix,
    required this.timeout,
  }) {
    if (Platform.isWindows != (prefix == 'windows')) {
      throw UnsupportedError('Installer capture host and prefix differ');
    }
    if (!['linux', 'macos', 'windows'].contains(prefix) ||
        timeout <= Duration.zero) {
      throw ArgumentError(
        'Expected native installer prefix and positive timeout',
      );
    }
  }

  final Directory output;
  final String prefix;
  final Duration timeout;
  final _commands = <Map<String, Object?>>[];
  bool _running = false;

  List<Map<String, Object?>> get commands => List.unmodifiable(_commands);

  Future<String> run(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int expectedExit = 0,
  }) async => utf8.decode(
    (await capture(
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      expectedExit: expectedExit,
    )).stdout,
    allowMalformed: true,
  );

  Future<({int exitCode, List<int> stdout, List<int> stderr})> capture(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int? expectedExit = 0,
    Duration? timeout,
    File? windowsStdinFile,
  }) async {
    if (_running) throw StateError('Installer commands must run sequentially');
    _running = true;
    final command = List<String>.unmodifiable(arguments);
    Map<String, Object?>? proof;
    try {
      try {
        proof = await executeSuite(
          '$prefix-${_commands.length}',
          command,
          workingDirectory ?? Directory.current.path,
          environment ?? Platform.environment,
          output,
          timeout: timeout ?? this.timeout,
          windowsStdinFile: windowsStdinFile,
          waitForWindowsJobEmpty: Platform.isWindows,
          onProof: (value) {
            _commands.add(
              Map<String, Object?>.unmodifiable({
                'arguments': command,
                'exit': value['exit_code'],
                for (final key in [
                  'stdout',
                  'stderr',
                  'stdout_sha256',
                  'stderr_sha256',
                ])
                  key: value[key],
              }),
            );
          },
        );
      } on SuiteExitFailure catch (failure) {
        if (expectedExit != null && failure.proof['exit_code'] != expectedExit)
          rethrow;
        proof = failure.proof;
      }
      if (expectedExit != null && proof['exit_code'] != expectedExit)
        throw SuiteExitFailure(proof);
      return (
        exitCode: proof['exit_code'] as int,
        stdout: readOrdinaryBytes(
          File(p.join(output.path, proof['stdout'] as String)),
        ),
        stderr: readOrdinaryBytes(
          File(p.join(output.path, proof['stderr'] as String)),
        ),
      );
    } finally {
      _running = false;
    }
  }
}
