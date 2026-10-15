// Original installed-command captures, shared by npm and pub route readers.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/windows_command.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

typedef InstalledProcessEvidence = ({
  List<String> arguments,
  int exitCode,
  List<int> stdout,
  List<int> stderr,
});

List<InstalledProcessEvidence> validateInstalledProcessReceipts(
  Object? rows,
  Directory directory, {
  required Set<int> timeoutSeconds,
  int Function(int index, List<String> arguments)? timeoutFor,
}) {
  if (timeoutSeconds.isEmpty || timeoutSeconds.any((value) => value <= 0)) {
    throw ArgumentError('Expected independently configured positive timeouts');
  }
  final commands = receiptList(rows);
  requireReceipt(
    commands.isNotEmpty && commands.length <= 4096,
    'Invalid installed process inventory',
  );
  final result = <InstalledProcessEvidence>[];
  for (var index = 0; index < commands.length; index++) {
    final row = receiptObject(commands[index]);
    final windows = row.containsKey('windows_execution');
    final fields = {
      'arguments',
      'exit',
      'stdout',
      'stderr',
      'stdout_sha256',
      'stderr_sha256',
      if (windows) 'windows_execution',
    };
    requireReceipt(
      row.length == fields.length && fields.every(row.containsKey),
      'Installed process row fields differ',
    );
    final arguments = receiptList(row['arguments']);
    requireReceipt(
      arguments.isNotEmpty &&
          arguments.every((arg) => arg is String && !arg.contains('\u0000')) &&
          (arguments.first as String).isNotEmpty &&
          row['exit'] is int,
      'Malformed installed process command or exit',
    );
    final suite = 'installed-$index';
    final original = receiptObject(
      readRecord(File(p.join(directory.path, '$suite.json'))),
    );
    final originalFields = {
      'suite',
      'command',
      'exit_code',
      'timed_out',
      'elapsed_seconds',
      'timeout_seconds',
      'stdout',
      'stderr',
      'stdout_sha256',
      'stderr_sha256',
      if (windows) 'windows_execution',
    };
    requireReceipt(
      original.length == originalFields.length &&
          originalFields.every(original.containsKey) &&
          original['suite'] == suite &&
          exactReceipt(original['command'], arguments) &&
          exactReceipt(original['exit_code'], row['exit']) &&
          (!windows ||
              exactReceipt(
                original['windows_execution'],
                row['windows_execution'],
              )),
      'Installed original execution identity differs',
    );
    requireReceipt(
      original['timed_out'] == false,
      'Installed original process timed out',
    );
    final timeout = original['timeout_seconds'],
        elapsed = original['elapsed_seconds'];
    requireReceipt(
      timeout is int &&
          timeoutSeconds.contains(timeout) &&
          elapsed is num &&
          elapsed.isFinite &&
          elapsed >= 0 &&
          elapsed <= timeout,
      'Installed original timeout or elapsed bound differs',
    );
    requireReceipt(
      timeoutFor == null ||
          timeout == timeoutFor(index, List<String>.unmodifiable(arguments)),
      'Installed original configured timeout differs',
    );
    if (windows) {
      final command = receiptObject(row['windows_execution']);
      requireReceipt(
        command.length == 3 &&
            command['application_name'] is String &&
            command['command_line'] is String &&
            exactReceipt(command['logical_arguments'], arguments),
        'Installed Windows execution identity differs',
      );
      try {
        WindowsRawCommandLine(
          applicationName: command['application_name'] as String,
          commandLine: command['command_line'] as String,
          logicalArguments: List<String>.from(arguments),
        );
      } on ArgumentError {
        throw const FormatException(
          'Installed Windows execution identity differs',
        );
      }
    }
    final streams = <String, List<int>>{};
    for (final stream in ['stdout', 'stderr']) {
      final name = '$suite.$stream.log';
      requireReceipt(
        row[stream] == name &&
            original[stream] == name &&
            row['${stream}_sha256'] == original['${stream}_sha256'],
        'Installed original stream identity differs',
      );
      streams[stream] = verifiedBytes(
        File(p.join(directory.path, name)),
        row['${stream}_sha256'],
      );
    }
    result.add((
      arguments: List<String>.unmodifiable(arguments),
      exitCode: row['exit'] as int,
      stdout: streams['stdout']!,
      stderr: streams['stderr']!,
    ));
  }
  return List.unmodifiable(result);
}
