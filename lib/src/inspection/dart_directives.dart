import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart' as state;
import 'package:analyzer/src/dart/sdk/sdk.dart';

import '../plan/repository_path.dart';
import 'project_evidence.dart';
import 'dart_resources.dart';
import 'dart_parts.dart';
import 'dart_packages.dart';
import 'dart_flutter.dart';
import 'physical_paths.dart';

/// Per-project directive acquisition. Evidence is appended immediately so that
/// a later failed directive does not discard earlier factual observations.
class DartDirectives {
  final ProjectRequest _request;
  final DartResources _resources;
  final String _sdkPath;
  final FolderBasedDartSdk _verifiedSdk;
  final FlutterSdk? _flutterSdk;
  final AnalysisContextCollection _collection;
  final List<Map<String, dynamic>> _facts;
  final List<Map<String, dynamic>> _unknowns;
  DartParts? _partIndex;
  bool _complete = true;
  bool get complete => _complete;

  DartDirectives(
    this._request,
    this._resources,
    this._sdkPath,
    this._verifiedSdk,
    this._flutterSdk,
    this._collection,
    this._facts,
    this._unknowns,
  );

  void _issue(String code, String message, [String? file, Object? range]) =>
      _unknowns.add({
        'code': code,
        'message': message,
        'path': file,
        'source_range': range,
      });

  Future<void> collect(
    ParsedUnitResult parsed,
    DriverBasedAnalysisContext context,
    String file,
    String contextId,
  ) async {
    final absolute = p.joinAll([_request.selection.root, ...file.split('/')]);
    _complete = true;
    final sourceState = context.driver.fsState.getFileForPath(absolute);
    var importIndex = 0, exportIndex = 0, partIndexInFile = 0;
    for (final directive in parsed.unit.directives) {
      if (directive is ast.PartDirective || directive is ast.PartOfDirective) {
        final range = _dartRange(parsed, file, directive);
        Map<String, Object?> resolution = {'kind': 'unresolved'};
        String specifier;
        String kind;
        if (directive is ast.PartDirective) {
          kind = 'part';
          specifier = directive.uri.stringValue ?? '';
          final part = sourceState.kind.partIncludes[partIndexInFile++];
          if (part is state.PartIncludeWithFile && part.includedPart != null) {
            resolution = _dartResolution(
              part.uris.primary,
              _request,
              _resources,
              _sdkPath,
              verifiedSdk: _verifiedSdk,
              context: context,
              sourcePath: absolute,
              flutterSdk: _flutterSdk,
              libraryTarget: false,
            );
            final target = File(part.includedFile.path)
                .resolveSymbolicLinksSync();
            bool proven;
            if (part.includedPart is state.PartOfUriFileKind) {
              proven =
                  dartUriPartOwner(target, _collection, _resources) ==
                  File(absolute).resolveSymbolicLinksSync();
            } else {
              _partIndex ??= DartParts(_collection, _resources);
              proven = _partIndex!.hasUniqueOwner(target);
            }
            if (!proven) {
              _complete = false;
              _issue(
                'DART_PART_OWNER_UNPROVEN',
                'Part target has ambiguous or incomplete containing-library discovery.',
                file,
                range,
              );
            }
          }
        } else {
          directive as ast.PartOfDirective;
          kind = 'part_of';
          specifier =
              directive.uri?.stringValue ??
              directive.libraryName?.toSource() ??
              '';
          final String? owner;
          if (directive.uri != null) {
            owner = dartUriPartOwner(absolute, _collection, _resources);
          } else {
            _partIndex ??= DartParts(_collection, _resources);
            owner = await _partIndex!.uniqueOwner(absolute, context);
          }
          if (owner != null) {
            final relative = repositoryRelativePath(
              _request.selection.root,
              owner,
            );
            try {
              if (relative == null ||
                  (normalizeRepositoryPath(relative) == relative &&
                      unicode.nfc(relative) == relative)) {
                resolution = {
                  'kind': 'local',
                  'path': relative,
                  'canonical_file_uri': fileUri(owner),
                  'via_path': null,
                };
              }
            } on FormatException {
              // Keep a nonportable physical owner unresolved.
            }
          }
        }
        if (resolution['kind'] == 'unresolved') {
          _complete = false;
          _issue(
            'DART_PART_OWNER_UNPROVEN',
            'A unique compatible physical part owner is not proven.',
            file,
            range,
          );
        }
        _facts.add({
          'context_id': contextId,
          'source': file,
          'source_range': range,
          'kind': kind,
          'specifier': specifier,
          'type_only': false,
          'resolution': resolution,
        });
        continue;
      }
      if (directive is! ast.NamespaceDirective) continue;
      final kind = directive is ast.ImportDirective ? 'import' : 'export';
      final uris = directive is ast.ImportDirective
          ? sourceState.kind.libraryImports[importIndex++].uris
          : sourceState.kind.libraryExports[exportIndex++].uris;
      final branches = [uris.primary, ...uris.configurations];
      final specifiers = [
        directive.uri.stringValue,
        ...directive.configurations.map((c) => c.uri.stringValue),
      ];
      if (branches.length != specifiers.length)
        throw const FormatException(
          'Compiler conditional URI evidence is inconsistent.',
        );
      final range = _dartRange(parsed, file, directive);
      for (var i = 0; i < branches.length; i++) {
        final resolution = _dartResolution(
          branches[i],
          _request,
          _resources,
          _sdkPath,
          verifiedSdk: _verifiedSdk,
          context: context,
          sourcePath: absolute,
          flutterSdk: _flutterSdk,
        );
        if (resolution['kind'] == 'unresolved') {
          _complete = false;
          _issue(
            'UNRESOLVED_IMPORT',
            'Dart $kind branch target is not proven.',
            file,
            range,
          );
        }
        _facts.add({
          'context_id': contextId,
          'source': file,
          'source_range': range,
          'kind': kind,
          'specifier': specifiers[i] ?? '',
          'type_only': false,
          'resolution': resolution,
        });
      }
    }
  }
}

Map<String, Object?> _dartRange(
  ParsedUnitResult parsed,
  String file,
  ast.AstNode node,
) {
  final start = parsed.lineInfo.getLocation(node.offset);
  final end = parsed.lineInfo.getLocation(node.end);
  return {
    'path': file,
    'start': {'line': start.lineNumber, 'column': start.columnNumber},
    'end': {'line': end.lineNumber, 'column': end.columnNumber},
  };
}

Map<String, Object?> _dartResolution(
  state.DirectiveUri uri,
  ProjectRequest request,
  DartResources resources,
  String sdkPath, {
  required FolderBasedDartSdk verifiedSdk,
  required DriverBasedAnalysisContext context,
  required String sourcePath,
  FlutterSdk? flutterSdk,
  bool libraryTarget = true,
}) {
  if (uri is! state.DirectiveUriWithFile || !uri.file.exists)
    return {'kind': 'unresolved'};
  if (libraryTarget && uri.file.kind is! state.LibraryFileKind)
    return {'kind': 'unresolved'};
  final logical = uri.file.path;
  resources.record(logical);
  final canonical = File(logical).resolveSymbolicLinksSync();
  final identity = uri.relativeUri.scheme == 'dart'
      ? uri.relativeUri
      : uri.source.uri;
  if (identity.scheme == 'dart' && p.isWithin(sdkPath, canonical)) {
    final selected = verifiedSdk.mapDartUri(identity.toString());
    if (selected != null &&
        resources.getFile(selected.fullName).exists &&
        resources.getFile(selected.fullName).resolveSymbolicLinksSync().path ==
            canonical) {
      return {'kind': 'builtin', 'identity': identity.toString()};
    }
  }
  if (flutterSdk?.builtin(uri, canonical, context, resources) ?? false) {
    return {'kind': 'builtin', 'identity': identity.toString()};
  }
  if (identity.scheme == 'dart') return {'kind': 'unresolved'};
  final origin = DartPackages(
    context,
    resources,
  ).classify(uri, canonical, sourcePath);
  if (origin == 'external') {
    return {'kind': 'external', 'identity': uri.source.uri.toString()};
  }
  if (origin == 'unresolved') return {'kind': 'unresolved'};
  if (logical != canonical && origin != 'local') return {'kind': 'unresolved'};
  final relative = repositoryRelativePath(request.selection.root, canonical);
  if (relative != null) {
    try {
      if (normalizeRepositoryPath(relative) != relative ||
          unicode.nfc(relative) != relative)
        return {'kind': 'unresolved'};
    } on FormatException {
      return {'kind': 'unresolved'};
    }
  }
  return {
    'kind': 'local',
    'path': repositoryRelativePath(request.selection.root, canonical),
    'canonical_file_uri': fileUri(canonical),
    'via_path': logical == canonical ? null : fileUri(logical),
  };
}
