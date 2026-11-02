import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/file_system.dart' as afs;
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart' as state;

import 'dart_resources.dart';

/// Uniqueness is over each declared context's analyzed files, prepared package
/// library folders, and compiler-reachable fixed point, never the whole disk.
/// This intentionally does not use discoverAvailableFiles (which can suppress
/// inventory errors and skip packages attributed to another context).
class DartParts {
  final _owners = <String, Set<String>>{};
  final _gaps = <String>[];
  final _clock = Stopwatch()..start();
  var _visitedCount = 0;

  DartParts(AnalysisContextCollection collection, DartResources resources) {
    for (final context
        in collection.contexts.cast<DriverBasedAnalysisContext>()) {
      try {
        _discover(context, resources);
      } catch (error) {
        _gaps.add(error.toString());
      }
    }
    _gaps.addAll(resources.failures);
  }

  void _budget() {
    if (_visitedCount > 100000 ||
        _clock.elapsed > const Duration(seconds: 120)) {
      throw const FormatException(
        'Part-owner discovery resource budget exhausted.',
      );
    }
  }

  void _discover(DriverBasedAnalysisContext context, DartResources resources) {
    final seeds = <String>{};
    final seenFolders = <String>{};
    void walk(afs.Folder folder) {
      _budget();
      try {
        resources.record(folder.path);
        if (!seenFolders.add(Directory(folder.path).resolveSymbolicLinksSync()))
          return;
        for (final child in folder.getChildren()) {
          if (child is afs.Folder) {
            walk(child);
          } else if (child is afs.File && child.path.endsWith('.dart')) {
            seeds.add(child.path);
          }
        }
      } catch (error) {
        _gaps.add('Package inventory ${folder.path}: $error');
      }
    }

    seeds.addAll(
      context.contextRoot.analyzedFiles().where((f) => f.endsWith('.dart')),
    );
    for (final folder
        in context.driver.sourceFactory.packageMap?.values ?? <afs.Folder>[]) {
      walk(folder);
    }
    for (final seed in seeds) {
      _budget();
      context.driver.fsState.getFileForPath(seed);
    }
    final visited = <state.FileState>{};
    void follow(state.DirectiveUris uris) {
      for (final uri in [uris.primary, ...uris.configurations]) {
        if (uri is state.DirectiveUriWithFile) {
          if (!uri.file.exists)
            _gaps.add('Missing reachable source ${uri.file.path}');
        } else {
          // Summary-only sources are not covered by this physical SDK route.
          _gaps.add('Unproven reachable physical source $uri');
        }
      }
    }

    while (true) {
      final pending = context.driver.knownFiles
          .where((f) => !visited.contains(f))
          .toList();
      if (pending.isEmpty) break;
      for (final file in pending) {
        _visitedCount++;
        _budget();
        visited.add(file);
        if (!file.exists) {
          _gaps.add('Missing discovered source ${file.path}');
          continue;
        }
        final parsed = context.currentSession.getParsedUnit(file.path);
        if (parsed is! ParsedUnitResult || parsed.diagnostics.isNotEmpty) {
          _gaps.add('Incomplete parse ${file.path}');
        }
        final kind = file.kind;
        for (final directive in kind.libraryImports) {
          follow(directive.uris);
        }
        for (final directive in kind.libraryExports) {
          follow(directive.uris);
        }
        for (final directive in kind.partIncludes) {
          follow(directive.uris);
        }
      }
    }
    for (final file in visited) {
      if (!file.exists || file.kind is! state.LibraryFileKind) continue;
      for (final part
          in file.kind.partIncludes.whereType<state.PartIncludeWithFile>()) {
        if (!part.includedFile.exists) continue;
        if (part.includedPart == null) {
          _gaps.add('Invalid containing library ${file.path}');
          continue;
        }
        resources.record(part.includedFile.path);
        final target = File(part.includedFile.path).resolveSymbolicLinksSync();
        _owners
            .putIfAbsent(target, () => {})
            .add(File(file.path).resolveSymbolicLinksSync());
      }
    }
  }

  bool hasUniqueOwner(String target) =>
      _gaps.isEmpty && _owners[target]?.length == 1;

  Future<String?> uniqueOwner(
    String path,
    DriverBasedAnalysisContext context,
  ) async {
    if (_gaps.isNotEmpty) return null;
    final candidates = _owners[File(path).resolveSymbolicLinksSync()];
    if (candidates == null || candidates.length != 1) return null;
    final result = await context.currentSession.getResolvedLibraryContaining(
      path,
    );
    if (result is! ResolvedLibraryResult) return null;
    final selected = File(result.element.firstFragment.source.fullName)
        .resolveSymbolicLinksSync();
    return candidates.single == selected ? selected : null;
  }
}

/// A URI part fixes its owner by compiler URI semantics, unlike a named part.
/// Prove the reciprocal direct-library include in every declared context and
/// deduplicate physical identities; do not trust the first selected owner.
String? dartUriPartOwner(
  String path,
  AnalysisContextCollection collection,
  DartResources resources,
) {
  final owners = <String>{};
  for (final context
      in collection.contexts.cast<DriverBasedAnalysisContext>()) {
    final parsed = context.currentSession.getParsedUnit(path);
    if (parsed is! ParsedUnitResult || parsed.diagnostics.isNotEmpty)
      return null;
    final kind = context.driver.fsState.getFileForPath(path).kind;
    if (kind is! state.PartOfUriKnownFileKind ||
        kind.includingContainer is! state.LibraryFileKind ||
        !kind.uriFile.exists)
      return null;
    final owner = kind.uriFile.path;
    final library = context.currentSession.getParsedUnit(owner);
    if (library is! ParsedUnitResult || library.diagnostics.isNotEmpty)
      return null;
    resources.record(owner);
    owners.add(File(owner).resolveSymbolicLinksSync());
  }
  return owners.length == 1 ? owners.single : null;
}
