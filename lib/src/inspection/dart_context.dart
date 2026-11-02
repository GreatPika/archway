import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart' as yaml;
import 'package:package_config/package_config_types.dart' as package_config;
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';

import '../plan/repository_path.dart';
import 'project_evidence.dart';
import 'dart_resources.dart';
import 'physical_paths.dart';

Map<String, Object?> describeDartContext(
  DriverBasedAnalysisContext context,
  ProjectRequest request,
  DartResources resources,
  String sdkVersion,
) {
  String normalize(String path) {
    symlinkHops(path);
    final canonical = File(path).resolveSymbolicLinksSync();
    return repositoryRelativePath(request.selection.root, canonical) ??
        fileUri(canonical);
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
    'sdk_version': sdkVersion,
  };
}
