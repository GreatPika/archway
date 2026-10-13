import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:yaml/yaml.dart' as yaml;
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import 'package:package_config/package_config_types.dart' as package_config;
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:analyzer/file_system/file_system.dart' as afs;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart' as state;
import 'package:analyzer/src/dart/sdk/sdk.dart';
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';

import '../plan/plan.dart';
import '../installation_layout.dart';
import '../native/physical_paths.dart';

part 'observations.dart';
part 'physical_paths.dart';
part 'helper_validation.dart';
part 'typescript_adapter.dart';
part 'runtime_process.dart';
part 'project_evidence.dart';
part 'dart_adapter.dart';
part 'dart_resources.dart';
part 'dart_parts.dart';
part 'dart_flutter.dart';
part 'dart_packages.dart';

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

class Inspection {
  final Future<Process> Function(
    String,
    List<String>, {
    required String workingDirectory,
    required Map<String, String> environment,
  })?
  startProcess;
  final Future<void>? cancelled;
  Inspection({this.startProcess, this.cancelled});

  Future<Report> check(RepositorySelection selection) async {
    final loaded = await Plan.load(selection);
    final plan = loaded.plan;
    final diagnostics = loaded.diagnostics
        .map(
          (d) => inspectionDiagnostic(
            d.code,
            d.message,
            severity: d.severity,
            path: d.path,
            pointer: d.rulePointer,
          ),
        )
        .toList();
    final violations = <Map<String, Object?>>[];
    final unknowns = <Map<String, Object?>>[];
    final warnings = <Map<String, Object?>>[];
    final errors = <Map<String, Object?>>[];
    final files = <Map<String, Object?>>[];
    final projects = <Map<String, Object?>>[];
    final facts = <Map<String, Object?>>[];
    final inputs = _Inputs(selection.root);
    final versions = <String, Object?>{
      'dart_adapter': null,
      'typescript_adapter': null,
      'dart_sdk': null,
      'node': null,
      'typescript': null,
    };
    if (plan != null) await _preparePhysicalLinks();
    if (loaded.policyHash != null) {
      final policyUri = _uri(p.join(selection.root, selection.policyPath));
      _Observation? physical;
      if (plan != null) {
        try {
          physical = await _observe(
            PhysicalPaths.fromFileUri(Uri.parse(policyUri)),
            'policy',
          );
        } catch (error) {
          errors.add(
            inspectionDiagnostic(
              'INPUT_OBSERVATION_FAILED',
              error.toString(),
              path: selection.policyPath,
            ),
          );
        }
      }
      inputs.add(
        _Observation(
          'file',
          policyUri,
          physical?.canonical ?? policyUri,
          loaded.policyHash!.substring(7),
          'policy',
          null,
          physical?.symlinkHops ?? [],
        ),
      );
      if (physical != null) {
        inputs.add(physical);
        try {
          for (final hop in physical.symlinkHops) {
            inputs.add(
              await _observe(
                PhysicalPaths.fromFileUri(Uri.parse(hop['observed_uri']!)),
                'policy',
              ),
            );
          }
        } catch (error) {
          errors.add(
            inspectionDiagnostic(
              'INPUT_OBSERVATION_FAILED',
              error.toString(),
              path: selection.policyPath,
            ),
          );
        }
      }
    }
    var complete = false;
    if (plan != null) {
      warnings.addAll(diagnostics.where((d) => d['severity'] == 'warning'));
      diagnostics.removeWhere((d) => d['severity'] == 'warning');
      final corpus = await _corpus(plan, inputs, unknowns, warnings);
      final runtime = _RuntimeProcesses(startProcess, cancelled);
      final adapter = _TypeScriptAdapter(runtime);
      final dartAdapter = _DartAdapter(runtime);
      final evidence = <String, ProjectEvidence>{};
      final orderedProjects = plan.projects.toList()
        ..sort((a, b) => comparePlanText(a.id, b.id));
      for (final project in orderedProjects) {
        {
          final request = ProjectRequest(
            'check:${project.id}',
            selection,
            project,
            corpus.where((f) => _language(f) == project.adapter).toList(),
          );
          final result = project.adapter == 'typescript'
              ? await adapter.inspect(request)
              : await dartAdapter.inspect(request);
          evidence[project.id] = result;
          for (final input in result._observations) {
            inputs.add(input);
          }
          for (final issue in result.unknowns) {
            unknowns.add(
              inspectionDiagnostic(
                issue['code'],
                issue['message'],
                project: project.id,
                path: issue['path'],
                range: issue['source_range'],
              ),
            );
          }
          for (final issue in result.toolErrors) {
            errors.add(
              inspectionDiagnostic(
                issue['code'],
                issue['message'],
                project: project.id,
                path: issue['path'],
                range: issue['source_range'],
              ),
            );
          }
        }
      }
      if (orderedProjects.any((p) => p.adapter == 'dart')) {
        versions['dart_adapter'] = '0.1.0';
        versions['dart_sdk'] = dartAdapter.sdkVersion;
      }
      if (orderedProjects.any((p) => p.adapter == 'typescript')) {
        versions['typescript_adapter'] = '0.1.0';
        versions['node'] = adapter.nodeVersion;
        versions['typescript'] = adapter.compilerVersion;
      }
      for (final file in corpus) {
        final language = _language(file);
        final relevant = orderedProjects.where((p) => p.adapter == language);
        final candidates = <Map<String, Object?>>[];
        final unresolved = <String>[];
        final analyses = <String>[];
        for (final project in relevant) {
          final result = evidence[project.id];
          if (result == null ||
              !result.discoveryComplete ||
              inputs.conflictedProjects.contains(project.id)) {
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
        final conflict = inputs.conflictedProjects.contains(project.id);
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
      try {
        (Zone.current[#archwayBeforeInputRecheck] as void Function()?)?.call();
        await inputs.recheck();
      } catch (error) {
        errors.add(
          inspectionDiagnostic('INPUT_RECHECK_FAILED', error.toString()),
        );
      }
      for (final changed in inputs.changed.toList()..sort(comparePlanText)) {
        unknowns.add(
          inspectionDiagnostic(
            'INPUT_CHANGED',
            'Observed input changed during inspection.',
            path: _publicPhysicalPath(
              _relative(
                selection.root,
                PhysicalPaths.fromFileUri(Uri.parse(changed)),
              ),
            ),
          ),
        );
      }
      if (runtime.cancelled) {
        errors.add(
          inspectionDiagnostic(
            'INSPECTION_CANCELLED',
            'Inspection was cancelled; verified evidence collected before cancellation is retained.',
          ),
        );
      }
      complete =
          unknowns.isEmpty &&
          errors.isEmpty &&
          inputs.rechecked &&
          files.every(
            (f) => f['assignment'] == 'assigned' && f['analysis'] == 'complete',
          ) &&
          projects.every((p) => p['status'] == 'complete');
    }
    for (final list in [violations, unknowns, warnings, errors, diagnostics]) {
      list.sort(_compareDiagnostics);
    }
    facts.sort(_compareFacts);
    final status = plan == null
        ? loaded.status
        : !complete
        ? 'incomplete'
        : violations.isNotEmpty
        ? 'negative'
        : 'ok';
    return Report(
      status,
      loaded.policyHash,
      {
        'policy_valid': plan != null,
        'analysis_complete': complete,
        'violations': violations,
        'unknowns': unknowns,
        'warnings': warnings,
        'tool_errors': errors,
        'observed': {
          'files': files.length,
          'analyzed_files': files
              .where((f) => {'complete', 'partial'}.contains(f['analysis']))
              .length,
          'edges': facts.length,
        },
        'coverage': {'projects': projects, 'files': files},
        'facts': {'edges': facts},
        'input_identity': inputs.toJson(),
        'scope': plan?.scope ?? [],
        'exclude': plan?.exclude ?? [],
        'projects': plan?.projectCount ?? 0,
        'nodes': plan?.nodeCount ?? 0,
      },
      diagnostics,
      versions,
    );
  }
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

int _compareDiagnostics(Map<String, Object?> a, Map<String, Object?> b) {
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

int _compareFacts(Map<String, Object?> a, Map<String, Object?> b) {
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
