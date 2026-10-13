part of 'inspection.dart';

/// Pinned analyzer implementation seams are intentional: see Dart feasibility
/// evidence. Upgrading analyzer requires re-verifying these source contracts.
class _DartAdapter {
  final _RuntimeProcesses runtime;
  _DartAdapter(this.runtime);
  String? sdkVersion;
  String? sdkPath;
  _FlutterSdk? flutterSdk;

  bool _prepared = false;
  Object? _preparationError;
  List<_Observation> _preparationInputs = [];

  Future<void> _prepare(String root, _DartResources resources) async {
    if (_prepared) {
      resources.observations.addAll(
        _preparationInputs.map(
          (o) => _Observation(
            o.kind,
            o.observed,
            o.canonical,
            o.hash,
            o.role,
            resources.project,
            o.symlinkHops,
          ),
        ),
      );
      if (_preparationError != null) throw _preparationError!;
      return;
    }
    _prepared = true;
    try {
      await _prepareRuntime(root, resources);
    } catch (error) {
      _preparationError = error;
      rethrow;
    } finally {
      _preparationInputs = List.of(resources.observations);
    }
  }

  Future<void> _prepareRuntime(String root, _DartResources resources) async {
    final cwd = await Directory.current.resolveSymbolicLinks();
    String? executable;
    for (final entry in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      if (entry.isEmpty || !p.isAbsolute(entry)) continue;
      final directory = p.normalize(entry);
      if (directory == cwd || directory == root || p.isWithin(root, directory))
        continue;
      final candidate = File(
        p.join(directory, Platform.isWindows ? 'dart.exe' : 'dart'),
      );
      if (!await candidate.exists()) continue;
      _symlinkHops(candidate.path);
      final canonical = await candidate.resolveSymbolicLinks();
      if (canonical == root ||
          p.isWithin(root, canonical) ||
          p.dirname(canonical) == cwd)
        continue;
      // A Flutter bin/dart entry is a launcher. Select its prepared embedded
      // binary directly: never run Flutter CLI or let it populate the cache.
      final embedded = resources.getFile(
        p.join(
          p.dirname(canonical),
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      final selected = embedded.exists
          ? embedded.resolveSymbolicLinksSync().path
          : canonical;
      if (selected == root ||
          p.isWithin(root, selected) ||
          p.dirname(selected) == cwd)
        continue;
      executable = selected;
      break;
    }
    if (executable == null)
      throw const FormatException('No external Dart SDK on PATH.');
    sdkPath = p.dirname(p.dirname(executable));
    final version = resources
        .getFile(p.join(sdkPath!, 'version'))
        .readAsStringSync()
        .trim();
    if (version != '3.13.3')
      throw FormatException('Dart SDK 3.13.3 required; found $version.');
    final output = utf8.decode(
      await runtime.run(
        executable,
        _TypeScriptAdapter(runtime).environment,
        ['--suppress-analytics', '--version'],
        const [],
        timeout: const Duration(seconds: 5),
        stdoutLimit: 65536,
        stderrLimit: 65536,
        totalLimit: 65536,
      ),
    );
    if (!output.startsWith('Dart SDK version: 3.13.3 '))
      throw const FormatException('Dart SDK executable and metadata disagree.');
    resources
        .getFile(p.join(sdkPath!, 'lib', 'libraries.json'))
        .readAsStringSync();
    resources
        .getFile(p.join(sdkPath!, 'lib', 'core', 'core.dart'))
        .readAsStringSync();
    flutterSdk = _FlutterSdk.selected(sdkPath!, resources);
    sdkVersion = version;
  }

  Future<ProjectEvidence> inspect(ProjectRequest request) async {
    final resources = _DartResources(request.project.id);
    final files = <String, Map<String, dynamic>>{
      for (final file in request.expectedFiles)
        file: {'membership': 'unknown', 'coverage': 'not_attempted'},
    };
    final contexts = <Map<String, Object?>>[];
    final facts = <Map<String, dynamic>>[];
    final unknowns = <Map<String, dynamic>>[];
    final errors = <Map<String, dynamic>>[];
    AnalysisContextCollection? collection;
    _DartParts? partIndex;
    void issue(String code, String message, [String? file, Object? range]) =>
        unknowns.add({
          'code': code,
          'message': message,
          'path': file,
          'source_range': range,
        });
    try {
      if (runtime.cancelled)
        throw const FormatException('Inspection cancelled.');
      await _prepare(request.selection.root, resources);
      final verifiedSdk = FolderBasedDartSdk(
        resources,
        resources.getFolder(sdkPath!),
      );
      final roots = request.project.packageRoots
          .map((s) => p.normalize(p.join(request.selection.root, s)))
          .toSet()
          .toList();
      collection = AnalysisContextCollection(
        includedPaths: roots,
        resourceProvider: resources,
        sdkPath: sdkPath,
      );
      for (final context
          in collection.contexts.cast<DriverBasedAnalysisContext>()) {
        final descriptor = _dartDescriptor(context, request, resources);
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
          final sourceState = context.driver.fsState.getFileForPath(absolute);
          var importIndex = 0, exportIndex = 0, partIndexInFile = 0;
          for (final directive in parsed.unit.directives) {
            if (directive is ast.PartDirective ||
                directive is ast.PartOfDirective) {
              final range = _dartRange(parsed, file, directive);
              Map<String, Object?> resolution = {'kind': 'unresolved'};
              String specifier;
              String kind;
              if (directive is ast.PartDirective) {
                kind = 'part';
                specifier = directive.uri.stringValue ?? '';
                final part = sourceState.kind.partIncludes[partIndexInFile++];
                if (part is state.PartIncludeWithFile &&
                    part.includedPart != null) {
                  resolution = _dartResolution(
                    part.uris.primary,
                    request,
                    resources,
                    sdkPath!,
                    verifiedSdk: verifiedSdk,
                    context: context,
                    sourcePath: absolute,
                    flutterSdk: flutterSdk,
                    libraryTarget: false,
                  );
                  final target = File(part.includedFile.path)
                      .resolveSymbolicLinksSync();
                  bool proven;
                  if (part.includedPart is state.PartOfUriFileKind) {
                    proven =
                        _dartUriPartOwner(target, collection, resources) ==
                        File(absolute).resolveSymbolicLinksSync();
                  } else {
                    partIndex ??= _DartParts(collection, resources);
                    proven =
                        partIndex.gaps.isEmpty &&
                        partIndex.owners[target]?.length == 1;
                  }
                  if (!proven) {
                    membership['coverage'] = 'partial';
                    issue(
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
                  owner = _dartUriPartOwner(absolute, collection, resources);
                } else {
                  partIndex ??= _DartParts(collection, resources);
                  owner = await partIndex.uniqueOwner(absolute, context);
                }
                if (owner != null) {
                  final relative = _relative(request.selection.root, owner);
                  try {
                    if (relative == null ||
                        (normalizeRepositoryPath(relative) == relative &&
                            unicode.nfc(relative) == relative)) {
                      resolution = {
                        'kind': 'local',
                        'path': relative,
                        'canonical_file_uri': _uri(owner),
                        'via_path': null,
                      };
                    }
                  } on FormatException {
                    // Keep a nonportable physical owner unresolved.
                  }
                }
              }
              if (resolution['kind'] == 'unresolved') {
                membership['coverage'] = 'partial';
                issue(
                  'DART_PART_OWNER_UNPROVEN',
                  'A unique compatible physical part owner is not proven.',
                  file,
                  range,
                );
              }
              facts.add({
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
                request,
                resources,
                sdkPath!,
                verifiedSdk: verifiedSdk,
                context: context,
                sourcePath: absolute,
                flutterSdk: flutterSdk,
              );
              if (resolution['kind'] == 'unresolved') {
                membership['coverage'] = 'partial';
                issue(
                  'UNRESOLVED_IMPORT',
                  'Dart $kind branch target is not proven.',
                  file,
                  range,
                );
              }
              facts.add({
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
      if (resources.failures.isNotEmpty)
        throw FormatException(resources.failures.join('; '));
    } catch (error) {
      if (error is _RuntimeFailure && error.cleanupUnconfirmed) {
        errors.add(_cleanupDiagnostic());
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

Map<String, Object?> _dartDescriptor(
  DriverBasedAnalysisContext context,
  ProjectRequest request,
  _DartResources resources,
) {
  String normalize(String path) {
    _symlinkHops(path);
    final canonical = File(path).resolveSymbolicLinksSync();
    return _relative(request.selection.root, canonical) ?? _uri(canonical);
  }

  List<String> paths(Iterable<String> values) =>
      values.map(normalize).toSet().toList()..sort(comparePlanText);
  final options = <String>{};
  for (final entry in context.contextRoot.optionsFileMap.entries) {
    final start = resources.readPaths.length;
    final parsed = AnalysisOptionsParseSession().parse(
      sourceFactory: context.driver.sourceFactory,
      contextRoot: context.contextRoot.root,
      file: entry.key,
    );
    if (parsed.diagnostics.isNotEmpty)
      throw const FormatException('Dart options graph is incomplete.');
    final sources = resources.readPaths.skip(start).toSet();
    options.addAll(sources);
    for (final source in sources) {
      final content = yaml.loadYaml(
        resources.getFile(source).readAsStringSync(),
      );
      final analyzer = content is Map ? content['analyzer'] : null;
      final experiments = analyzer is Map
          ? analyzer['enable-experiment']
          : null;
      if ((content is Map && content['plugins'] != null) ||
          (analyzer is Map && analyzer['plugins'] != null)) {
        throw const FormatException(
          'Plugin-dependent Dart analysis is unsupported.',
        );
      }
      if (experiments is List && experiments.isNotEmpty) {
        throw const FormatException(
          'Experimental Dart analysis flags are unsupported.',
        );
      }
    }
  }
  final packages = context.contextRoot.packagesFile;
  if (packages == null)
    throw const FormatException('Prepared package_config.json is required.');
  final contents = resources.getFile(packages.path).readAsStringSync();
  package_config.PackageConfig.parseString(contents, File(packages.path).uri);
  final config = jsonDecode(contents);
  if (config is! Map || config['configVersion'] != 2)
    throw const FormatException(
      'Prepared package config version 2 is required.',
    );
  final entries = config['packages'];
  if (entries is List) {
    for (final entry in entries) {
      final version = entry is Map ? entry['languageVersion'] : null;
      final match = version is String
          ? RegExp(r'^(2|3)\.([0-9]+)$').firstMatch(version)
          : null;
      if (match == null ||
          (match[1] == '2'
              ? int.parse(match[2]!) < 12 || int.parse(match[2]!) > 19
              : int.parse(match[2]!) > 13)) {
        throw const FormatException(
          'Unsupported prepared package language version.',
        );
      }
    }
  }
  if (entries is! List ||
      !entries.any((entry) {
        if (entry is! Map || entry['rootUri'] is! String) return false;
        final uri = File(packages.path).uri.resolve(entry['rootUri'] as String);
        if (uri.scheme != 'file') return false;
        final root = p.normalize(uri.toFilePath());
        return root == context.contextRoot.root.path ||
            p.isWithin(root, context.contextRoot.root.path);
      }))
    throw const FormatException(
      'Declared context lacks a prepared package mapping.',
    );
  final checkedFolders = <String>{};
  for (final path in [
    ...context.contextRoot.includedPaths,
    ...request.expectedFiles
        .map((file) => p.joinAll([request.selection.root, ...file.split('/')]))
        .where(context.contextRoot.isAnalyzed)
        .map(p.dirname),
  ]) {
    var folder = path;
    while (checkedFolders.add(folder)) {
      final manifest = resources.getFile(p.join(folder, 'pubspec.yaml'));
      if (manifest.exists) {
        final pubspec = yaml.loadYaml(manifest.readAsStringSync());
        final name = pubspec is Map ? pubspec['name'] : null;
        if (name is! String ||
            !entries.any((entry) {
              if (entry is! Map ||
                  entry['name'] != name ||
                  entry['rootUri'] is! String)
                return false;
              final uri = File(packages.path).uri
                  .resolve(entry['rootUri'] as String);
              return uri.scheme == 'file' &&
                  resources
                          .getFolder(p.normalize(uri.toFilePath()))
                          .resolveSymbolicLinksSync()
                          .path ==
                      resources
                          .getFolder(folder)
                          .resolveSymbolicLinksSync()
                          .path;
            })) {
          throw const FormatException(
            'Package manifest disagrees with the selected prepared mapping.',
          );
        }
        break;
      }
      if (folder == context.contextRoot.root.path) break;
      final parent = p.dirname(folder);
      if (parent == folder) break;
      folder = parent;
    }
  }
  return {
    'excluded_paths': paths(context.contextRoot.excludedPaths),
    'included_paths': paths(context.contextRoot.includedPaths),
    'options_paths': paths(options),
    'package_config_path': normalize(packages.path),
    'root': normalize(context.contextRoot.root.path),
    'sdk_version': '3.13.3',
  };
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
  _DartResources resources,
  String sdkPath, {
  required FolderBasedDartSdk verifiedSdk,
  required DriverBasedAnalysisContext context,
  required String sourcePath,
  _FlutterSdk? flutterSdk,
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
  final origin = _DartPackages(
    context,
    resources,
  ).classify(uri, canonical, sourcePath);
  if (origin == 'external') {
    return {'kind': 'external', 'identity': uri.source.uri.toString()};
  }
  if (origin == 'unresolved') return {'kind': 'unresolved'};
  if (logical != canonical && origin != 'local') return {'kind': 'unresolved'};
  final relative = _relative(request.selection.root, canonical);
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
    'path': _relative(request.selection.root, canonical),
    'canonical_file_uri': _uri(canonical),
    'via_path': logical == canonical ? null : _uri(logical),
  };
}
