/// Finite decision model, not a simulation or certification of Dart/TS SDKs.
String assign(Map file) {
  if (file['supported_source'] != true) return 'unsupported';
  if (file['discovery_complete'] != true) return 'failed';
  final candidates = {
    for (final candidate in file['candidates'])
      (candidate['project_id'], candidate['context_id']),
  };
  return candidates.isEmpty
      ? 'missing'
      : candidates.length == 1
      ? 'assigned'
      : 'ambiguous';
}
