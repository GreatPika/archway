// Original installed CLI streams, using the cross-platform acceptance owner.
import 'dart:io';
import 'dart:typed_data';

import '../validation/json_values.dart';

import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../../test/support/windows_command.dart';
import 'native_acceptance.dart';

final class InstalledCommandRecorder {
  InstalledCommandRecorder({
    required this.output,
    this.timeout = const Duration(seconds: 30),
    this.windowsCommandFor,
  });

  final Directory output;
  final Duration timeout;
  final WindowsRawCommandLine? Function(List<String>)? windowsCommandFor;
  final _commands = <Map<String, Object?>>[];
  bool _running = false;
  List<Map<String, Object?>> get commands => List.unmodifiable(_commands);

  Future<NativeProcessResult> capture(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int expectedExit = 0,
    Duration? timeout,
    WindowsRawCommandLine? windowsCommand,
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
          windowsCommand: windowsCommand ?? windowsCommandFor?.call(command),
          onProof: (value) => _commands.add(
            Map<String, Object?>.unmodifiable({
              'arguments': command,
              if (value.containsKey('windows_execution'))
                'windows_execution': value['windows_execution'],
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

const maxEvidenceFileBytes = 128 * 1024 * 1024;

List<int> readOrdinaryBytes(File file, {int limit = maxEvidenceFileBytes}) {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !sameEvidencePath(
        file.resolveSymbolicLinksSync(),
        file.absolute.path,
        p.context,
      )) {
    throw const FormatException('Aliased or nonordinary evidence file');
  }
  final input = file.openSync();
  try {
    if (input.lengthSync() > limit) {
      throw const FormatException('Evidence file exceeds bound');
    }
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final chunk = input.readSync((limit - bytes.length + 1).clamp(1, 65536));
      if (chunk.isEmpty) return bytes.takeBytes();
      bytes.add(chunk);
      if (bytes.length > limit) {
        throw const FormatException('Evidence file exceeds bound');
      }
    }
  } finally {
    input.closeSync();
  }
}

bool sameEvidencePath(String a, String b, p.Context paths) {
  // PurePosixPath preserves exactly two leading slashes as a distinct root.
  bool doubleRoot(String path) =>
      path.startsWith('//') && !path.startsWith('///');
  if (paths.style == p.Style.posix && doubleRoot(a) != doubleRoot(b)) {
    return false;
  }
  List<String> parts(String value) => paths
      .split(value)
      .where((part) => part.isNotEmpty && part != '.')
      .map(
        (part) => paths.style == p.Style.windows
            ? part.replaceAll('/', r'\').toLowerCase()
            : part,
      )
      .toList();
  return sameJson(parts(a), parts(b));
}
