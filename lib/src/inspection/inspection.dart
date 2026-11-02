import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../plan/policy_definition.dart';
import '../plan/policy_loader.dart';
import '../plan/repository_path.dart';
import '../native/physical_paths.dart';
import 'assessment.dart';
import 'corpus.dart';
import 'dart_adapter.dart';
import 'input_observation.dart';
import 'observations.dart';
import 'physical_paths.dart';
import 'project_evidence.dart';
import 'report.dart';
import 'runtime_process.dart';

export 'report.dart' show Report;

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
    final loaded = await loadPlan(selection);
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
    final inputs = ObservedInputs(selection.root);
    final versions = <String, Object?>{
      'dart_adapter': null,
      'typescript_adapter': null,
      'dart_sdk': null,
      'node': null,
      'typescript': null,
    };
    if (plan != null) await preparePhysicalLinks();
    if (loaded.policyHash != null) {
      final policyUri = fileUri(p.join(selection.root, selection.policyPath));
      InputObservation? physical;
      if (plan != null) {
        try {
          physical = await observeInput(
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
        InputObservation(
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
              await observeInput(
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
      final corpus = await enumerateCorpus(plan, inputs, unknowns, warnings);
      final runtime = RuntimeProcesses(startProcess, cancelled);
      final dartAdapter = DartAdapter(runtime);
      final evidence = <String, ProjectEvidence>{};
      final orderedProjects = plan.projects.toList()
        ..sort((a, b) => comparePlanText(a.id, b.id));
      for (final project in orderedProjects) {
        {
          final request = ProjectRequest(
            'check:${project.id}',
            selection,
            project,
            corpus.where((f) => sourceLanguage(f) == project.adapter).toList(),
          );
          // Private deterministic fault seam for cross-project input changes.
          // No CLI or environment control; absent in ordinary execution.
          (Zone.current[#archwayBeforeProjectInspection]
                  as void Function(String)?)
              ?.call(project.id);
          final result = await dartAdapter.inspect(request);
          evidence[project.id] = result;
          for (final input in result.observations) {
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
      final assessment = assessEvidence(
        plan,
        corpus,
        evidence,
        inputs.conflictedProjects,
      );
      files.addAll(assessment.files);
      projects.addAll(assessment.projects);
      facts.addAll(assessment.facts);
      violations.addAll(assessment.violations);
      unknowns.addAll(assessment.unknowns);
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
            path: publicPhysicalPath(
              repositoryRelativePath(
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
      list.sort(compareInspectionDiagnostics);
    }
    facts.sort(compareInspectionFacts);
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
