import '../plan/repository_path.dart';

/// Inspection-owned result; CLI supplies the versioned transport envelope.
class Report {
  final String status;
  final String? policyHash;
  final Map<String, Object?> payload;
  final List<Map<String, Object?>> diagnostics;
  final Map<String, Object?> toolVersions;
  Report(
    this.status,
    this.policyHash,
    this.payload,
    this.diagnostics,
    this.toolVersions,
  );
  int get exitCode => status == 'ok'
      ? 0
      : status == 'negative'
      ? 1
      : 2;
}

Map<String, Object?> inspectionDiagnostic(
  String code,
  String message, {
  String severity = 'error',
  String? path,
  String? pointer,
  String? project,
  Object? range,
}) => {
  'code': code,
  'severity': severity,
  'message': message,
  'rule_pointer': pointer,
  'source_range': range,
  'project_id': project,
  'path': path,
  'recovery_hints': <String>[],
};

int _nullableCompare(Object? a, Object? b) => a == null
    ? (b == null ? 0 : -1)
    : b == null
    ? 1
    : a is int && b is int
    ? a.compareTo(b)
    : comparePlanText(a.toString(), b.toString());
int _compareRanges(Object? a, Object? b) {
  if (a == null || b == null) return _nullableCompare(a, b);
  final left = a as Map, right = b as Map;
  for (final end in ['start', 'end']) {
    for (final coordinate in ['line', 'column']) {
      final c = _nullableCompare(left[end][coordinate], right[end][coordinate]);
      if (c != 0) return c;
    }
  }
  return 0;
}

int compareInspectionDiagnostics(
  Map<String, Object?> a,
  Map<String, Object?> b,
) {
  for (final key in [
    'path',
    'source_range',
    'code',
    'rule_pointer',
    'project_id',
    'message',
  ]) {
    final c = key == 'source_range'
        ? _compareRanges(a[key], b[key])
        : _nullableCompare(a[key], b[key]);
    if (c != 0) return c;
  }
  return 0;
}

int compareInspectionFacts(Map<String, Object?> a, Map<String, Object?> b) {
  for (final key in [
    'source',
    'source_range',
    'kind',
    'specifier',
    'resolution',
    'project_id',
    'context_id',
  ]) {
    final c = key == 'source_range'
        ? _compareRanges(a[key], b[key])
        : _nullableCompare(a[key], b[key]);
    if (c != 0) return c;
  }
  return 0;
}
