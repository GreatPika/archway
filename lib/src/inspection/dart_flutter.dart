part of 'inspection.dart';

/// Flutter is selected by the external Dart runtime, never by an import's name
/// or an untrusted package-map claim. This checks prepared installation
/// consistency, not authenticity of downloaded bytes.
class _FlutterSdk {
  final String root;
  final String version;
  final String revision;
  _FlutterSdk(this.root, this.version, this.revision);

  static _FlutterSdk? selected(String dartSdk, _DartResources resources) {
    if (p.basename(dartSdk) != 'dart-sdk' ||
        p.basename(p.dirname(dartSdk)) != 'cache' ||
        p.basename(p.dirname(p.dirname(dartSdk))) != 'bin')
      return null;
    final root = p.dirname(p.dirname(p.dirname(dartSdk)));
    final metadata = jsonDecode(
      resources
          .getFile(p.join(root, 'bin', 'cache', 'flutter.version.json'))
          .readAsStringSync(),
    );
    if (metadata is! Map ||
        metadata['channel'] != 'stable' ||
        metadata['dartSdkVersion'] != '3.13.3' ||
        metadata['frameworkVersion'] is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$')
            .hasMatch(metadata['frameworkVersion'] as String) ||
        metadata['frameworkRevision'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$')
            .hasMatch(metadata['frameworkRevision'] as String)) {
      throw const FormatException(
        'A stable Flutter SDK embedding Dart 3.13.3 is required.',
      );
    }
    final engine = resources
        .getFile(p.join(root, 'bin', 'cache', 'engine.stamp'))
        .readAsStringSync()
        .trim();
    if (engine != metadata['engineRevision']) {
      throw const FormatException(
        'Flutter engine cache disagrees with its SDK manifest.',
      );
    }
    return _FlutterSdk(
      root,
      metadata['frameworkVersion'] as String,
      metadata['frameworkRevision'] as String,
    );
  }

  bool builtin(
    state.DirectiveUriWithFile uri,
    String target,
    DriverBasedAnalysisContext context,
    _DartResources resources,
  ) {
    try {
      final packages = context.contextRoot.packagesFile!;
      final config = jsonDecode(
        resources.getFile(packages.path).readAsStringSync(),
      ) as Map;
      final declaredRoot = config['flutterRoot'];
      if (declaredRoot != null &&
          (declaredRoot is! String ||
              Uri.parse(declaredRoot).scheme != 'file' ||
              resources
                      .getFolder(
                        p.normalize(Uri.parse(declaredRoot).toFilePath()),
                      )
                      .resolveSymbolicLinksSync()
                      .path !=
                  root))
        return false;
      final identity = uri.relativeUri.scheme == 'dart'
          ? uri.relativeUri
          : uri.source.uri;
      final isDart = identity.scheme == 'dart';
      for (final entry in config['packages'] as List) {
        final name = entry['name'];
        if (name is! String || !RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name))
          continue;
        if (isDart && name != 'sky_engine') continue;
        final mapped = File(packages.path).uri
            .resolve(entry['rootUri'] as String);
        if (mapped.scheme != 'file' || entry['packageUri'] != 'lib/') continue;
        final trusted = [
          p.join(root, 'packages', name),
          p.join(root, 'bin', 'cache', 'pkg', name),
        ];
        if (!trusted.any(
          (candidate) => p.isWithin(p.join(candidate, 'lib'), target),
        ))
          continue;
        final packageRoot = resources
            .getFolder(p.normalize(mapped.toFilePath()))
            .resolveSymbolicLinksSync()
            .path;
        if (!trusted.contains(packageRoot)) continue;
        final lib = p.join(packageRoot, 'lib');
        if (!p.isWithin(lib, target)) continue;
        final mappedLib = context.driver.sourceFactory.packageMap?[name]?.path;
        if (mappedLib == null ||
            resources.getFolder(mappedLib).resolveSymbolicLinksSync().path !=
                lib)
          continue;
        final pubspec = yaml.loadYaml(
          resources
              .getFile(p.join(packageRoot, 'pubspec.yaml'))
              .readAsStringSync(),
        );
        if (pubspec is! Map || pubspec['name'] != name) return false;
        // Missing lock is allowed when independent SDK mapping proves origin;
        // a contradictory existing row must never be overridden by containment.
        final lock = resources.getFile(
          p.join(p.dirname(p.dirname(packages.path)), 'pubspec.lock'),
        );
        if (lock.exists) {
          final content = yaml.loadYaml(lock.readAsStringSync());
          final rows = content is Map ? content['packages'] : null;
          final row = rows is Map ? rows[name] : null;
          if (row != null &&
              (row is! Map ||
                  row['source'] != 'sdk' ||
                  row['description'] != 'flutter' ||
                  row['version'] != (pubspec['version'] ?? '0.0.0')))
            return false;
        }
        if (isDart) {
          final embedder = yaml.loadYaml(
            resources.getFile(p.join(lib, '_embedder.yaml')).readAsStringSync(),
          );
          final libraries = embedder is Map ? embedder['embedded_libs'] : null;
          final path = libraries is Map ? libraries[identity.toString()] : null;
          if (path is! String) return false;
          // Embedder paths use URI-style separators even on Windows.
          // The analyzer provider requires normalized filesystem paths.
          final expected = resources
              .getFile(p.normalize(p.join(lib, path)))
              .resolveSymbolicLinksSync()
              .path;
          return expected == target && p.isWithin(lib, expected);
        }
        return true;
      }
    } catch (_) {
      // A missing or contradictory join affects this reference, preserving
      // independently proven relative and normal SDK references.
    }
    return false;
  }
}
