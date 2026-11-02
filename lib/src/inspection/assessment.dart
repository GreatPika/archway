import '../plan/plan.dart';
import '../plan/repository_path.dart';
import 'project_evidence.dart';
import 'report.dart';

/// Assignment and policy evaluation over facts already acquired by Inspection.
/// Conflicts are the pre-recheck conflicts; late input changes do not erase facts.
class InspectionAssessment {
  final files = <Map<String, Object?>>[];
  final projects = <Map<String, Object?>>[];
  final facts = <Map<String, Object?>>[];
  final violations = <Map<String, Object?>>[];
  final unknowns = <Map<String, Object?>>[];
}

InspectionAssessment assessEvidence(
  Plan plan,
  List<String> corpus,
  Map<String, ProjectEvidence> evidence,
  Set<String> conflictedProjects,
) {
  final result = InspectionAssessment();
  final files = result.files, projects = result.projects, facts = result.facts;
  final violations = result.violations, unknowns = result.unknowns;
  final orderedProjects = plan.projects.toList()
    ..sort((a, b) => comparePlanText(a.id, b.id));
  for (final file in corpus) {
    final language = sourceLanguage(file);
    final relevant = orderedProjects.where((p) => p.adapter == language);
    final candidates = <Map<String, Object?>>[];
    final unresolved = <String>[];
    final analyses = <String>[];
    for (final project in relevant) {
      final result = evidence[project.id];
      if (result == null ||
          !result.discoveryComplete ||
          conflictedProjects.contains(project.id)) {
        unresolved.add(project.id);
      }
      for (final membership
          in result?.memberships(file) ?? <Map<String, dynamic>>[]) {
        candidates.add({
          'project_id': project.id,
          'context_id': membership['context_id'],
        });
        analyses.add(membership['coverage'] as String);
      }
    }
    candidates.sort((a, b) {
      final project = comparePlanText(
        a['project_id'] as String,
        b['project_id'] as String,
      );
      return project != 0
          ? project
          : comparePlanText(
              a['context_id'] as String,
              b['context_id'] as String,
            );
    });
    final assignment = language == 'unsupported'
        ? 'unsupported'
        : unresolved.isNotEmpty
        ? 'failed'
        : candidates.isEmpty
        ? 'missing'
        : candidates.length > 1
        ? 'ambiguous'
        : 'assigned';
    final analysis = analyses.isEmpty
        ? 'not_attempted'
        : assignment == 'assigned'
        ? analyses.single
        : analyses.any((s) => s == 'complete' || s == 'partial')
        ? 'partial'
        : 'failed';
    files.add({
      'path': file,
      'project_id': assignment == 'assigned'
          ? candidates.single['project_id']
          : null,
      'context_id': assignment == 'assigned'
          ? candidates.single['context_id']
          : null,
      'candidates': candidates,
      'assignment': assignment,
      'analysis': analysis,
      'discovery_complete': unresolved.isEmpty,
      'unresolved_project_ids': unresolved,
    });
    if (plan.owner(file).ownerId == null) {
      violations.add(
        inspectionDiagnostic(
          'SOURCE_UNOWNED',
          'Source has no declared owner.',
          path: file,
        ),
      );
    }
    final code = switch (assignment) {
      'unsupported' => 'UNSUPPORTED_SOURCE_KIND',
      'missing' => 'ANALYSIS_CONTEXT_MISSING',
      'ambiguous' => 'ANALYSIS_CONTEXT_AMBIGUOUS',
      'failed' => 'ANALYSIS_CONTEXT_DISCOVERY_FAILED',
      _ => null,
    };
    if (code != null) {
      unknowns.add(
        inspectionDiagnostic(
          code,
          'Source assignment is $assignment.',
          path: file,
        ),
      );
    }
  }
  for (final project in orderedProjects) {
    final result = evidence[project.id];
    final conflict = conflictedProjects.contains(project.id);
    final members = files
        .where(
          (f) => (f['candidates'] as List).any(
            (c) => c['project_id'] == project.id,
          ),
        )
        .toList();
    projects.add({
      'project_id': project.id,
      'adapter': project.adapter,
      'status': conflict
          ? 'partial'
          : result == null || result.status == 'failed'
          ? 'failed'
          : result.status == 'complete'
          ? 'complete'
          : 'partial',
      'contexts': result?.contexts ?? [],
      'files': members.length,
      'analyzed_files': members
          .where((f) => {'complete', 'partial'}.contains(f['analysis']))
          .length,
    });
    if (result == null || conflict) continue;
    for (final raw in result.facts) {
      final edge = <String, Object?>{
        'project_id': project.id,
        'context_id': raw['context_id'] ?? result.contextId,
        for (final key in [
          'source',
          'source_range',
          'kind',
          'specifier',
          'type_only',
          'resolution',
        ])
          key: raw[key],
      };
      facts.add(edge);
      final violation = _boundary(plan, edge);
      if (violation != null) violations.add(violation);
    }
  }
  return result;
}

Map<String, Object?>? _boundary(Plan plan, Map<String, Object?> edge) {
  final target = edge['resolution'] as Map;
  if (target['kind'] != 'local') return null;
  final source = edge['source'] as String;
  final path = target['path'] as String?;
  final ownership = path == null ? 'outside_scope' : plan.owner(path).ownership;
  String? code, pointer;
  if (ownership != 'owned') {
    code = switch (ownership) {
      'excluded' => 'LOCAL_TARGET_EXCLUDED',
      'outside_scope' => 'LOCAL_TARGET_OUTSIDE_SCOPE',
      _ => 'LOCAL_TARGET_UNOWNED',
    };
  } else if (plan.owner(source).ownerId != null) {
    final decision = plan.allowsPaths(source, path!);
    if (decision.decision == 'denied') {
      final private = decision.reason == 'target_not_public';
      code = private ? 'TARGET_NOT_PUBLIC' : 'DEPENDENCY_NOT_ALLOWED';
      final owner = plan.owner(private ? path : source).ownerId;
      final index = plan.nodes.singleWhere((n) => n.id == owner).policyIndex;
      pointer = '/nodes/$index/${private ? 'public' : 'allows'}';
    }
  }
  return code == null
      ? null
      : inspectionDiagnostic(
          code,
          'Local dependency violates the declared boundary.',
          path: source,
          project: edge['project_id'] as String,
          range: edge['source_range'],
          pointer: pointer,
        );
}
