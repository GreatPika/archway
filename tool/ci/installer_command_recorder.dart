import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_acceptance.dart';
import 'release_execution_receipts.dart';

/// Sequential POSIX installer evidence; privilege prefixes belong to the caller.
final class InstallerCommandRecorder {
  InstallerCommandRecorder({
    required this.output,
    required this.prefix,
    required this.timeout,
  }) {
    if (Platform.isWindows) {
      throw UnsupportedError(
        'POSIX installer capture does not cover Windows installer lifecycle',
      );
    }
    if (!['linux', 'macos'].contains(prefix) || timeout <= Duration.zero) {
      throw ArgumentError('Expected linux/macos prefix and positive timeout');
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
          timeout: timeout,
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
        if (failure.proof['exit_code'] != expectedExit) rethrow;
        proof = failure.proof;
      }
      if (proof['exit_code'] != expectedExit) throw SuiteExitFailure(proof);
      return utf8.decode(
        readOrdinaryBytes(File(p.join(output.path, proof['stdout'] as String))),
        allowMalformed: true,
      );
    } finally {
      _running = false;
    }
  }
}
