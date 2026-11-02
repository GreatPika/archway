import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/sdk/sdk.dart';

import '../plan/repository_path.dart';
import 'project_evidence.dart';
import 'dart_resources.dart';
import 'dart_runtime.dart';
import 'dart_context.dart';
import 'dart_directives.dart';
import 'runtime_process.dart';

/// Pinned analyzer implementation seams are intentional: see Dart feasibility
/// evidence. Upgrading analyzer requires re-verifying these source contracts.
class DartAdapter {
  final RuntimeProcesses _runtime;
  final DartRuntime _dartRuntime;
  DartAdapter(this._runtime) : _dartRuntime = DartRuntime(_runtime);
  String? get sdkVersion => _dartRuntime.sdkVersion;

  Future<ProjectEvidence> inspect(ProjectRequest request) async {
    final resources = DartResources(request.project.id);
    final files = <String, Map<String, dynamic>>{
      for (final file in request.expectedFiles)
        file: {'membership': 'unknown', 'coverage': 'not_attempted'},
    };
    final contexts = <Map<String, Object?>>[];
    final facts = <Map<String, dynamic>>[];
    final unknowns = <Map<String, dynamic>>[];
    final errors = <Map<String, dynamic>>[];
    AnalysisContextCollection? collection;
    void issue(String code, String message, [String? file, Object? range]) =>
        unknowns.add({
          'code': code,
          'message': message,
          'path': file,
          'source_range': range,
        });
    try {
      if (_runtime.cancelled)
        throw const FormatException('Inspection cancelled.');
      await _dartRuntime.prepare(request.selection.root, resources);
      final verifiedSdk = FolderBasedDartSdk(
        resources,
        resources.getFolder(_dartRuntime.sdkPath!),
      );
      final roots = request.project.packageRoots
          .map((s) => p.normalize(p.join(request.selection.root, s)))
          .toSet()
          .toList();
      collection = AnalysisContextCollection(
        includedPaths: roots,
        resourceProvider: resources,
        sdkPath: _dartRuntime.sdkPath,
      );
      final directives = DartDirectives(
        request,
        resources,
        _dartRuntime.sdkPath!,
        verifiedSdk,
        _dartRuntime.flutterSdk,
        collection,
        facts,
        unknowns,
      );
      for (final context
          in collection.contexts.cast<DriverBasedAnalysisContext>()) {
        final descriptor = describeDartContext(
          context,
          request,
          resources,
          _dartRuntime.sdkVersion!,
        );
        final contextId =
            'dart:${request.project.id}:${sha256.convert(utf8.encode(jsonEncode(descriptor)))}';
        contexts.add({'context_id': contextId, 'descriptor': descriptor});
        // Force the real context inventory; independent corpus remains authoritative.
        context.contextRoot.analyzedFiles().toList();
        for (final file in request.expectedFiles) {
          final absolute = p.joinAll([
            request.selection.root,
            ...file.split('/'),
          ]);
          final participates = roots.any(
            (r) => r == absolute || p.isWithin(r, absolute),
          );
          if (!participates || !context.contextRoot.isAnalyzed(absolute)) {
            if (files[file]!['membership'] == 'unknown')
              files[file]!['membership'] = 'non_member';
            continue;
          }
          final associations = files[file]!.putIfAbsent(
            'contexts',
            () => <Map<String, dynamic>>[],
          ) as List<Map<String, dynamic>>;
          final membership = <String, dynamic>{
            'context_id': contextId,
            'coverage': 'complete',
          };
          associations.add(membership);
          files[file]!['membership'] = 'member';
          final parsed = context.currentSession.getParsedUnit(absolute);
          if (parsed is! ParsedUnitResult) {
            membership['coverage'] = 'failed';
            issue('DART_ANALYSIS_FAILED', 'No physical parsed unit.', file);
            continue;
          }
          if (parsed.diagnostics.isNotEmpty) {
            membership['coverage'] = 'partial';
            issue('DART_PARSE_ERROR', 'Source has syntax errors.', file);
          }
          final language = parsed.unit.languageVersion;
          final effective = language.effective;
          if (effective.major < 2 ||
              (effective.major == 2 &&
                  (effective.minor < 12 || effective.minor > 19)) ||
              effective.major > 3 ||
              (effective.major == 3 && effective.minor > 13) ||
              (language.override != null &&
                  language.override! > language.package)) {
            membership['coverage'] = 'partial';
            issue(
              'UNSUPPORTED_ANALYSIS_CONFIGURATION',
              'Dart language version is outside the pinned supported package envelope.',
              file,
            );
          }
          try {
            await directives.collect(parsed, context, file, contextId);
          } finally {
            if (!directives.complete) membership['coverage'] = 'partial';
          }
        }
      }
      if (resources.failures.isNotEmpty)
        throw FormatException(resources.failures.join('; '));
    } catch (error) {
      if (error is RuntimeFailure && error.cleanupDiagnostic != null) {
        errors.add(error.cleanupDiagnostic!);
      }
      errors.add({
        'code': sdkVersion == null
            ? 'DART_SDK_UNAVAILABLE'
            : 'DART_ANALYSIS_FAILED',
        'message': error.toString(),
      });
    } finally {
      await collection?.dispose();
    }
    contexts.sort(
      (a, b) =>
          comparePlanText(a['context_id'] as String, b['context_id'] as String),
    );
    return ProjectEvidence(
      request,
      errors.isNotEmpty
          ? 'failed'
          : unknowns.isNotEmpty
          ? 'partial'
          : 'complete',
      contexts,
      files,
      facts,
      resources.observations,
      unknowns,
      errors,
    );
  }
}
