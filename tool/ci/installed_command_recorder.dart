// Original installed CLI streams, using the cross-platform acceptance owner.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import 'native_acceptance.dart';
import 'release_execution_receipts.dart';

final class InstalledCommandRecorder {
  InstalledCommandRecorder({
    required this.output,
    this.timeout = const Duration(seconds: 30),
  });

  final Directory output;
  final Duration timeout;
  final _commands = <Map<String, Object?>>[];
  bool _running = false;
  List<Map<String, Object?>> get commands => List.unmodifiable(_commands);

  Future<NativeProcessResult> capture(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int expectedExit = 0,
    Duration? timeout,
  }) async {
    if (_running) throw StateError('Installed commands must run sequentially');
    _running = true;
    final command = List<String>.unmodifiable(arguments);
    late Map<String, Object?> proof;
    try {
      try {
        proof = await executeSuite(
          'installed-${_commands.length}',
          command,
          workingDirectory ?? Directory.current.path,
          environment ?? Platform.environment,
          output,
          timeout: timeout ?? this.timeout,
          onProof: (value) => _commands.add(
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
          ),
        );
      } on SuiteExitFailure catch (failure) {
        if (failure.proof['exit_code'] != expectedExit) rethrow;
        proof = failure.proof;
      }
      if (proof['exit_code'] != expectedExit) throw SuiteExitFailure(proof);
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
