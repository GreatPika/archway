import 'dart:convert';

import '../plan/repository_path.dart';

const archwayVersion = '0.1.0';

class CliStreams {
  final StringSink stdout;
  final StringSink stderr;
  const CliStreams(this.stdout, this.stderr);
}

Map<String, Object?> cliDiagnostic(
  String code,
  String severity,
  String message, {
  String? pointer,
  String? path,
  List<String> hints = const [],
}) => {
  'code': code,
  'severity': severity,
  'message': message,
  'rule_pointer': pointer,
  'source_range': null,
  'project_id': null,
  'path': path,
  'recovery_hints': hints,
};

int cliUsage(
  CliStreams streams,
  String? command,
  String message, {
  Map<String, Object?>? exportPayload,
}) => cliFailure(
  streams,
  command,
  'USAGE_ERROR',
  message,
  usage: true,
  exportPayload: exportPayload,
);

int cliFailure(
  CliStreams streams,
  String? command,
  String code,
  String message, {
  bool usage = false,
  Map<String, Object?>? exportPayload,
  String? root,
}) {
  final exit = usage ? 64 : 2;
  final output = command == 'export' ? streams.stderr : streams.stdout;
  output.writeln(
    jsonEncode({
      'command': command,
      'schema_version': 1,
      'tool_versions': {
        'archway': archwayVersion,
        'dart_adapter': null,
        'typescript_adapter': null,
        'dart_sdk': null,
        'node': null,
        'typescript': null,
      },
      'resolved_root': root,
      'policy_path': null,
      'policy_hash': null,
      'status': usage ? 'usage_error' : 'error',
      'exit_code': exit,
      'diagnostics': [cliDiagnostic(code, 'error', message)],
      'payload': command == 'export'
          ? exportPayload ?? {'format': null, 'out': null}
          : null,
    }),
  );
  return exit;
}

int writeCliResult({
  required CliStreams streams,
  required String? command,
  required String root,
  required String? policyPath,
  required String? policyHash,
  required String status,
  required int exitCode,
  required List<Map<String, Object?>> diagnostics,
  required Map<String, Object?> inspectionVersions,
  required Object? payload,
  required String? mermaid,
  required bool exportToStdout,
  required Map<String, Object?> exportPayload,
}) {
  diagnostics.sort((a, b) {
    for (final key in [
      'path',
      'code',
      'rule_pointer',
      'project_id',
      'message',
    ]) {
      final av = a[key] as String?;
      final bv = b[key] as String?;
      final comparison = av == null
          ? (bv == null ? 0 : -1)
          : bv == null
          ? 1
          : comparePlanText(av, bv);
      if (comparison != 0) return comparison;
    }
    return 0;
  });
  if (command == 'export' && exitCode == 0 && exportToStdout) {
    streams.stdout.write(mermaid!);
  }
  if (command == 'export' && diagnostics.isEmpty) return exitCode;
  final output = command == 'export' ? streams.stderr : streams.stdout;
  output.writeln(
    jsonEncode({
      'command': command,
      'schema_version': 1,
      'tool_versions': {
        'archway': archwayVersion,
        'dart_adapter': null,
        'typescript_adapter': null,
        'dart_sdk': null,
        'node': null,
        'typescript': null,
        ...inspectionVersions,
      },
      'resolved_root': root,
      'policy_path': policyPath,
      'policy_hash': policyHash,
      'status': status,
      'exit_code': exitCode,
      'diagnostics': diagnostics,
      'payload': command == 'export' ? exportPayload : payload,
    }),
  );
  return exitCode;
}
