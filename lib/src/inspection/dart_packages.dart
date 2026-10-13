part of 'inspection.dart';

/// Joins the compiler's final physical target to the selected pub instance.
/// Null means no package mapping applies to this ordinary physical reference.
class _DartPackages {
  final DriverBasedAnalysisContext context;
  final _DartResources resources;
  _DartPackages(this.context, this.resources);

  Map? manifest(String root) {
    final file = resources.getFile(p.join(root, 'pubspec.yaml'));
    if (!file.exists) return null;
    final value = yaml.loadYaml(file.readAsStringSync());
    return value is Map ? value : null;
  }

  Map? effective(String root) {
    final spec = manifest(root);
    if (spec == null) return null;
    final result = Map.of(spec);
    final file = resources.getFile(p.join(root, 'pubspec_overrides.yaml'));
    if (file.exists) {
      final overrides = yaml.loadYaml(file.readAsStringSync());
      if (overrides is! Map)
        throw const FormatException('Invalid pub overrides.');
      for (final key in ['workspace', 'resolution', 'dependency_overrides']) {
        if (overrides.containsKey(key)) result[key] = overrides[key];
      }
    }
    return result;
  }

  Map<String, Map> workspace(String configRoot) {
    final spec = effective(configRoot);
    if (spec == null) return {};
    final result = <String, Map>{configRoot: spec};
    final members = spec['workspace'];
    if (members == null) return result;
    if (members is! List) throw const FormatException('Invalid workspace.');
    for (final member in members) {
      if (member is! String || p.isAbsolute(member) || member.contains('*')) {
        throw const FormatException('Unsupported workspace member.');
      }
      final root = canonicalRoot(p.normalize(p.join(configRoot, member)));
      final manifest = effective(root);
      if (manifest == null ||
          manifest['resolution'] != 'workspace' ||
          result.containsKey(root)) {
        throw const FormatException('Conflicting workspace membership.');
      }
      if (manifest['workspace'] != null) {
        throw const FormatException(
          'Nested workspace membership is unsupported.',
        );
      }
      result[root] = manifest;
    }
    return result;
  }

  bool remote(Object? value, {bool git = false}) {
    final uri = value is String ? Uri.tryParse(value) : null;
    return (uri != null &&
            [
              'https',
              'http',
              if (git) 'ssh',
              if (git) 'git',
            ].contains(uri.scheme) &&
            uri.host.isNotEmpty) ||
        (git &&
            value is String &&
            RegExp(r'^[^/@:\s]+@[^/:\s]+:[^\s]+$').hasMatch(value));
  }

  String? gitOrigin(String configPath) {
    final text = resources.getFile(configPath).readAsStringSync();
    String? section, origin;
    for (final line in const LineSplitter().convert(text)) {
      final value = line.trim();
      if (value.startsWith('[')) {
        if (value.toLowerCase().startsWith('[include')) return null;
        section = value;
      } else if (section == '[remote "origin"]' && value.startsWith('url')) {
        final match = RegExp(r'^url\s*=\s*(\S+)$').firstMatch(value);
        if (match == null || origin != null) return null;
        origin = match[1];
      }
    }
    return origin;
  }

  bool gitInstance(Map description, String root) {
    final url = description['url'];
    final commit = description['resolved-ref'];
    final path = description['path'];
    // Pub lock subpaths are portable slash-separated metadata, not native
    // Windows paths. Apply host path operations only when locating the checkout.
    if (!remote(url, git: true) ||
        commit is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit) ||
        path is! String ||
        path.contains(r'\') ||
        p.posix.isAbsolute(path) ||
        p.windows.rootPrefix(path).isNotEmpty ||
        p.posix.normalize(path) != path ||
        p.posix.split(path).contains('..'))
      return false;
    var checkout = root;
    if (path != '.') {
      for (final _ in p.posix.split(path)) {
        checkout = p.dirname(checkout);
      }
    }
    if (canonicalRoot(p.normalize(p.join(checkout, path))) != root) return false;
    final git = p.join(checkout, '.git');
    if (resources.getFile(p.join(git, 'HEAD')).readAsStringSync().trim() !=
        commit)
      return false;
    final origin = gitOrigin(p.join(git, 'config'));
    if (origin == url) return true;
    // Pub's ordinary prepared clone points to its local bare cache. Join that
    // cache's declared remote without invoking Git or trusting directory names.
    return origin != null &&
        p.isAbsolute(origin) &&
        gitOrigin(p.normalize(p.join(origin, 'config'))) == url;
  }

  String canonicalRoot(String root) =>
      resources.getFolder(root).resolveSymbolicLinksSync().path;

  String? owner(String file) {
    var folder = p.dirname(file);
    while (true) {
      if (manifest(folder) != null) return canonicalRoot(folder);
      final parent = p.dirname(folder);
      if (parent == folder) return null;
      folder = parent;
    }
  }

  String? classify(
    state.DirectiveUriWithFile uri,
    String target,
    String source,
  ) {
    try {
      final configFile = context.contextRoot.packagesFile!;
      final config = jsonDecode(
        resources.getFile(configFile.path).readAsStringSync(),
      );
      if (config is! Map || config['configVersion'] != 2) return 'unresolved';
      final candidates = <Map>[];
      for (final entry in config['packages'] as List) {
        if (entry is! Map || entry['rootUri'] is! String) continue;
        final rootUri = File(configFile.path).uri.resolve(entry['rootUri']);
        if (rootUri.scheme != 'file') continue;
        final libUri = Uri.directory(rootUri.toFilePath())
            .resolve(entry['packageUri'] as String? ?? '');
        if (libUri.scheme != 'file') continue;
        final libPath = p.normalize(libUri.toFilePath());
        // Match the final physical target, including imports bypassing a
        // configured root alias. An unrelated absent mapping proves nothing.
        final folder = resources.getFolder(libPath);
        if (!folder.exists) continue;
        final lib = folder.resolveSymbolicLinksSync().path;
        if (!p.isWithin(lib, target)) continue;
        final root = canonicalRoot(p.normalize(rootUri.toFilePath()));
        final name = entry['name'];
        final mapped = context.driver.sourceFactory.packageMap?[name]?.path;
        if (mapped == null || canonicalRoot(mapped) != lib) return 'unresolved';
        candidates.add({'name': name, 'root': root, 'lib': lib});
      }
      if (candidates.isEmpty)
        return uri.relativeUri.scheme == 'package' ? 'unresolved' : null;
      final depth = candidates
          .map((candidate) => p.split(candidate['lib'] as String).length)
          .reduce((a, b) => a > b ? a : b);
      candidates.removeWhere(
        (candidate) => p.split(candidate['lib'] as String).length != depth,
      );
      final targetOwner = owner(target);
      final targetSpec = targetOwner == null ? null : manifest(targetOwner);
      candidates.removeWhere(
        (candidate) =>
            candidate['root'] != targetOwner ||
            candidate['name'] != targetSpec?['name'],
      );
      if (candidates.length != 1) return 'unresolved';
      final selected = candidates.single;
      final root = selected['root'] as String;
      final name = selected['name'];
      if (uri.relativeUri.scheme == 'package' &&
          uri.relativeUri.pathSegments.first != name)
        return 'unresolved';
      final spec = manifest(root);
      if (spec == null || spec['name'] != name || owner(target) != root)
        return 'unresolved';
      final configRoot = canonicalRoot(p.dirname(p.dirname(configFile.path)));
      if (owner(source) == root && root == configRoot) return 'local';
      final members = workspace(configRoot);
      final overrides = <Map>[];
      for (final member in members.entries) {
        final values = member.value['dependency_overrides'];
        if (values is Map && values.containsKey(name))
          overrides.add({'value': values[name], 'root': member.key});
      }
      if (overrides.length > 1) return 'unresolved';
      final sourceRoot = owner(source) ?? configRoot;
      final sourceSpec = effective(sourceRoot);
      final dependencies = sourceSpec?['dependencies'];
      final devDependencies = sourceSpec?['dev_dependencies'];
      final declaredRoot = overrides.isNotEmpty
          ? overrides.single['root'] as String
          : sourceRoot;
      final declared = overrides.isNotEmpty
          ? overrides.single['value']
          : dependencies is Map && dependencies.containsKey(name)
          ? dependencies[name]
          : devDependencies is Map
          ? devDependencies[name]
          : null;
      final declarations = [
        declared,
        if (overrides.isEmpty)
          for (final member in members.values)
            for (final section in ['dependencies', 'dev_dependencies'])
              if (member[section] is Map &&
                  (member[section] as Map).containsKey(name))
                member[section][name],
      ];
      final installedVersion = semver.Version.parse(
        spec['version'] as String? ?? '0.0.0',
      );
      for (final declaration in declarations) {
        final constraint = declaration is Map
            ? declaration['version']
            : declaration;
        if ((constraint != null && constraint is! String) ||
            !semver.VersionConstraint.parse(constraint as String? ?? 'any')
                .allows(installedVersion)) {
          return 'unresolved';
        }
      }
      final declaredSource = declared is Map
          ? [
              'path',
              'git',
              'sdk',
              'hosted',
            ].where(declared.containsKey).toList()
          : <String>[];
      if (members.containsKey(root) &&
          members[root]!['name'] == name &&
          (root != configRoot || members.containsKey(owner(source)))) {
        if (declaredSource.contains('git') || declaredSource.contains('sdk'))
          return 'unresolved';
        if (declared is Map &&
            declared['path'] != null &&
            (declared['path'] is! String ||
                canonicalRoot(
                      p.normalize(p.join(declaredRoot, declared['path'])),
                    ) !=
                    root))
          return 'unresolved';
        return 'local';
      }
      final lock = resources.getFile(p.join(configRoot, 'pubspec.lock'));
      if (!lock.exists) return 'unresolved';
      final content = yaml.loadYaml(lock.readAsStringSync());
      final rows = content is Map ? content['packages'] : null;
      final row = rows is Map ? rows[name] : null;
      if (row is! Map || row['version'] != (spec['version'] ?? '0.0.0'))
        return 'unresolved';
      if (declaredSource.length > 1 ||
          (declaredSource.isNotEmpty && declaredSource.single != row['source']))
        return 'unresolved';
      final description = row['description'];
      if (row['source'] == 'path' &&
          description is Map &&
          description['path'] is String &&
          description['relative'] is bool) {
        final path = description['path'] as String;
        if (description['relative'] == p.isAbsolute(path)) return 'unresolved';
        final expected = canonicalRoot(p.normalize(p.join(configRoot, path)));
        if (expected != root) return 'unresolved';
        if (declared is Map &&
            declared['path'] is String &&
            canonicalRoot(
                  p.normalize(p.join(declaredRoot, declared['path'])),
                ) !=
                root)
          return 'unresolved';
        return 'local';
      }
      if (row['source'] == 'git' && description is Map) {
        final git = declared is Map ? declared['git'] : null;
        final requested = git is String ? {'url': git} : git;
        if (requested is Map &&
            (requested['url'] != description['url'] ||
                (requested['path'] ?? '.') != description['path'] ||
                (requested['ref'] != null &&
                    requested['ref'] != description['ref'])))
          return 'unresolved';
        return gitInstance(description, root) ? 'external' : 'unresolved';
      }
      final hosted = declared is Map ? declared['hosted'] : null;
      final hostedUrl = hosted is String
          ? hosted
          : hosted is Map
          ? hosted['url']
          : null;
      if (row['source'] == 'hosted' &&
          hostedUrl != null &&
          (description is! Map || hostedUrl != description['url']))
        return 'unresolved';
      if (hosted is Map && hosted['name'] != null && hosted['name'] != name)
        return 'unresolved';
      if (row['source'] == 'hosted' &&
          description is Map &&
          description['name'] == name &&
          remote(description['url']) &&
          description['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(description['sha256'])) {
        return 'external';
      }
      return 'unresolved';
    } catch (_) {
      return 'unresolved';
    }
  }
}
