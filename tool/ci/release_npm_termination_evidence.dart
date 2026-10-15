// Bind termination summaries to their independently retained original streams.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/windows_command.dart';
import 'release_execution_receipts.dart';
import 'release_installed_output_receipts.dart';
import 'release_receipt_values.dart';

void validateNpmTerminationEvidence(
  Map<String, dynamic> phase,
  Directory processes, {
  required String target,
  required String route,
  required List<String> prefix,
  required InstalledOutputValidator outputValidator,
}) {
  final windows = target == 'windows-x64',
      cached = route == 'cache' && target != 'windows-x64';
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  final name = phase['termination_directory'];
  requireReceipt(
    name is String && RegExp(r'^termination-[A-Za-z0-9_-]+$').hasMatch(name),
    'Invalid termination evidence directory',
  );
  final directory = Directory(p.join(processes.path, name as String));
  requireReceipt(
    directory.resolveSymbolicLinksSync() == directory.path,
    'Aliased termination evidence directory',
  );
  final summary = receiptObject(phase['termination']);
  final expectedFiles = <String>{};
  final events = windows
      ? ['TerminateProcess']
      : ['SIGINT', 'SIGTERM', 'SIGHUP'];
  final native = paths.join(
    phase['payload'] as String,
    'bin',
    target,
    windows ? 'archway.exe' : 'archway',
  );
  final suffix = ['--root', phase['project'] as String, 'check'];
  for (var eventIndex = 0; eventIndex < events.length; eventIndex++) {
    final event = events[eventIndex];
    final observations =
        <
          String,
          ({Map<String, dynamic> record, List<int> out, List<int> err})
        >{};
    final roles = [
      'route',
      'native',
      if (cached) ...['outer', if (event == 'SIGINT') 'group'],
    ];
    for (final role in roles) {
      final stem = '${event.toLowerCase()}-$role';
      expectedFiles.addAll([
        '$stem.json',
        '$stem.stdout.log',
        '$stem.stderr.log',
      ]);
      final record = receiptObject(
        readRecord(File(p.join(directory.path, '$stem.json'))),
      );
      final arguments = [
        if (role == 'native')
          native
        else if (cached && role == 'route')
          phase['shim'] as String
        else
          ...prefix,
        ...suffix,
      ];
      final execution = record['windows_execution'];
      final fields = {
        'command',
        'route',
        'stimulus',
        'exit',
        'pids',
        'failure',
        'cleanup_failures',
        'observation',
        'stdout_sha256',
        'stderr_sha256',
        if (execution != null) 'windows_execution',
      };
      final pids = receiptObject(record['pids']);
      requireReceipt(
        record.length == fields.length &&
            fields.every(record.containsKey) &&
            exactReceipt(record['command'], arguments) &&
            record['route'] == role &&
            record['stimulus'] == event &&
            record['failure'] == null &&
            exactReceipt(record['cleanup_failures'], []) &&
            pids.length == 2 &&
            pids['core'] is int &&
            pids['helper'] is int &&
            pids['core'] > 0 &&
            pids['helper'] > 0 &&
            pids['core'] != pids['helper'],
        'Termination original command, readiness or cleanup differs',
      );
      if (windows && arguments.first.toLowerCase().endsWith('.cmd')) {
        final raw = receiptObject(execution);
        requireReceipt(
          raw.length == 3 &&
              raw['application_name'] is String &&
              raw['command_line'] is String &&
              exactReceipt(raw['logical_arguments'], arguments),
          'Termination Windows shim execution differs',
        );
        try {
          WindowsRawCommandLine(
            applicationName: raw['application_name'] as String,
            commandLine: raw['command_line'] as String,
            logicalArguments: arguments,
          );
        } on ArgumentError {
          throw const FormatException(
            'Termination Windows shim execution differs',
          );
        }
      } else {
        requireReceipt(
          execution == null,
          'Unexpected termination shell transport',
        );
      }
      observations[role] = (
        record: record,
        out: verifiedBytes(
          File(p.join(directory.path, '$stem.stdout.log')),
          record['stdout_sha256'],
        ),
        err: verifiedBytes(
          File(p.join(directory.path, '$stem.stderr.log')),
          record['stderr_sha256'],
        ),
      );
    }
    final direct = observations['native']!, wrapped = observations['route']!;
    final expected = receiptObject(receiptList(summary['cases'])[eventIndex]);
    requireReceipt(
      direct.record['observation'] == null &&
          wrapped.record['observation'] == null &&
          exactReceipt(direct.record['exit'], expected['native_exit']) &&
          exactReceipt(wrapped.record['exit'], expected['route_exit']) &&
          exactReceipt(direct.out, wrapped.out) &&
          exactReceipt(direct.err, wrapped.err),
      'Termination native/route original parity differs',
    );
    if (!windows && event == 'SIGINT') {
      _cancelled(
        direct.out,
        direct.err,
        outputValidator,
        phase['project'] as String,
      );
    }
    if (cached) {
      final outer = observations['outer']!;
      final boundary = receiptObject(
        receiptList(
          receiptObject(summary['outer_npm_pid_observations'])['cases'],
        )[eventIndex],
      );
      final unconfirmed = outer.record['observation'];
      final equal =
          unconfirmed == null &&
          outer.record['exit'] == direct.record['exit'] &&
          exactReceipt(outer.out, direct.out) &&
          exactReceipt(outer.err, direct.err);
      requireReceipt(
        boundary['case'] == event &&
            boundary['status'] == (equal ? 'PASSED' : 'FAILED'),
        'Outer npm observation was relabeled as owned success',
      );
      if (unconfirmed != null) {
        final observed = receiptObject(unconfirmed);
        requireReceipt(
          exactReceipt(boundary['observation'], observed) &&
              observed['outcome'] == 'termination-unconfirmed' &&
              observed['stdout_bytes'] is int &&
              observed['stdout_bytes'] >= 0 &&
              observed['stdout_bytes'] <= outer.out.length &&
              observed['stderr_bytes'] is int &&
              observed['stderr_bytes'] >= 0 &&
              observed['stderr_bytes'] <= outer.err.length,
          'Outer npm unconfirmed observation differs',
        );
      } else {
        requireReceipt(
          exactReceipt(boundary['observation'], {
            'outer_exit': outer.record['exit'],
            'stdout_bytes': outer.out.length,
            'stderr_bytes': outer.err.length,
            'core_terminated': true,
            'streams_equal':
                exactReceipt(outer.out, direct.out) &&
                exactReceipt(outer.err, direct.err),
          }),
          'Outer npm original streams differ',
        );
      }
      if (event == 'SIGINT') {
        final group = observations['group']!,
            receipt = receiptObject(summary['cache_group_sigint']);
        requireReceipt(
          group.record['observation'] == null &&
              exactReceipt(group.record['exit'], receipt['outer_exit']) &&
              group.record['exit'] != 0 &&
              utf8.decode(group.err) == receipt['stderr'],
          'Actual npm-exec group observation differs',
        );
        _cancelled(
          group.out,
          group.err,
          outputValidator,
          phase['project'] as String,
          allowStderr: true,
        );
      }
    }
  }
  final entries = directory.listSync(followLinks: false);
  requireReceipt(
    entries.length == expectedFiles.length &&
        entries.every(
          (entry) =>
              entry is File && expectedFiles.contains(p.basename(entry.path)),
        ),
    'Termination evidence inventory differs',
  );
}

void _cancelled(
  List<int> output,
  List<int> errors,
  InstalledOutputValidator validator,
  String project, {
  bool allowStderr = false,
}) {
  requireReceipt(
    output.isNotEmpty &&
        output.last == 10 &&
        output.where((byte) => byte == 10).length == 1 &&
        !exactReceipt(output.take(3).toList(), [239, 187, 191]) &&
        (allowStderr || errors.isEmpty),
    'Cancelled original streams differ',
  );
  final value = validator.publicResult(
    (arguments: const [], exitCode: 2, stdout: output, stderr: const []),
    command: 'check',
    code: 2,
    status: 'incomplete',
    analysisComplete: false,
  );
  final payload = receiptObject(value['payload']);
  requireReceipt(
    value['resolved_root'] == project &&
        receiptList(payload['tool_errors']).any(
          (entry) => receiptObject(entry)['code'] == 'INSPECTION_CANCELLED',
        ),
    'Cancelled original envelope differs',
  );
}
