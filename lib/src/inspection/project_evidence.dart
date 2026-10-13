part of 'inspection.dart';

/// Owned by Inspection; adapters receive the complete relevant corpus.
class ProjectRequest {
  final String requestId;
  final RepositorySelection selection;
  final PlanProject project;
  final List<String> expectedFiles;
  ProjectRequest(
    this.requestId,
    this.selection,
    this.project,
    List<String> expectedFiles,
  ) : expectedFiles = List.unmodifiable(expectedFiles);
}

/// Validated factual evidence, never policy decisions or a CLI envelope.
class ProjectEvidence {
  final ProjectRequest request;
  final String status;
  final List<Map<String, Object?>> contexts;
  final Map<String, Map<String, dynamic>> files;
  final List<Map<String, dynamic>> facts;
  final List<_Observation> _observations;
  final List<Map<String, dynamic>> unknowns;
  final List<Map<String, dynamic>> toolErrors;
  ProjectEvidence(
    this.request,
    this.status,
    this.contexts,
    this.files,
    this.facts,
    this._observations,
    this.unknowns,
    this.toolErrors,
  );
  bool get discoveryComplete =>
      toolErrors.isEmpty &&
      files.values.every((f) => f['membership'] != 'unknown');
  List<Map<String, dynamic>> memberships(String file) {
    final row = files[file];
    if (row == null || row['membership'] != 'member') return [];
    final associations = row['contexts'];
    return associations is List
        ? associations.cast<Map<String, dynamic>>()
        : [
            {'context_id': contextId, 'coverage': row['coverage']},
          ];
  }

  String get contextId => contexts.single['context_id'] as String;
}
