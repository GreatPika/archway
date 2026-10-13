part of 'inspection.dart';

/// All analyzer filesystem reads use this provider. Unknown operations fail
/// closed; no persistent byte store or plugin state directory is supplied.
class _DartResources implements afs.ResourceProvider {
  final base = PhysicalResourceProvider.INSTANCE;
  final String project;
  final observations = <_Observation>[];
  final readPaths = <String>[];
  final failures = <String>[];
  final _seen = <String>{};
  bool _recordingAliases = false;
  _DartResources(this.project);

  void record(String path, [List<int>? bytes]) {
    final route = PhysicalPaths.trace(path);
    final hops = route.hops;
    final type = FileSystemEntity.typeSync(path);
    final observed = _uri(path);
    String? canonical, hash;
    String kind;
    if (type == FileSystemEntityType.notFound) {
      kind = 'absent';
    } else {
      canonical = _uri(File(path).resolveSymbolicLinksSync());
      if (_uri(route.path) != canonical)
        throw FileSystemException(
          'Physical pathname spelling is ambiguous',
          path,
        );
      if (type == FileSystemEntityType.file) {
        kind = 'file';
        hash = sha256.convert(bytes ?? File(path).readAsBytesSync()).toString();
      } else if (type == FileSystemEntityType.directory) {
        kind = 'directory';
        final names = <String>{};
        final entries = Directory(path).listSync(followLinks: false).map((
          entry,
        ) {
          final name = p.basename(entry.path);
          final type = FileSystemEntity.typeSync(
            entry.path,
            followLinks: false,
          );
          if (!_listedEntryMatches(entry, type) ||
              !names.add(name) ||
              utf8.decode(utf8.encode('x$name')) != 'x$name') {
            throw FileSystemException(
              'Directory entry is unrepresentable or changed',
              path,
            );
          }
          return [name, _inventoryKind(type)];
        }).toList()..sort((a, b) => comparePlanText(a[0], b[0]));
        hash = sha256.convert(utf8.encode(jsonEncode(entries))).toString();
      } else {
        throw FileSystemException('Unsupported analyzer input type', path);
      }
    }
    final role = path.endsWith('.dart') ? 'source' : 'config';
    final item = _Observation(
      kind,
      observed,
      canonical,
      hash,
      role,
      project,
      hops,
    );
    if (_seen.add('$observed|${item.identity}')) observations.add(item);
    if (!_recordingAliases && hops.isNotEmpty) {
      _recordingAliases = true;
      try {
        for (final alias in hops) {
          record(PhysicalPaths.fromFileUri(Uri.parse(alias['observed_uri']!)));
        }
      } finally {
        _recordingAliases = false;
      }
    }
  }

  @override
  p.Context get pathContext => base.pathContext;
  @override
  afs.File getFile(String path) => _DartFile(this, base.getFile(path));
  @override
  afs.Folder getFolder(String path) => _DartFolder(this, base.getFolder(path));
  @override
  afs.Resource getResource(String path) {
    record(path);
    return wrap(base.getResource(path));
  }

  afs.Resource wrap(afs.Resource r) =>
      r is afs.File ? _DartFile(this, r) : _DartFolder(this, r as afs.Folder);
  @override
  afs.Folder? getStateLocation(String pluginId) => null;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError(
    'Untraced analyzer provider operation ${i.memberName}',
  );
}

abstract class _DartResource implements afs.Resource {
  @override
  final _DartResources provider;
  final afs.Resource base;
  _DartResource(this.provider, this.base);
  @override
  String get path => base.path;
  @override
  String get shortName => base.shortName;
  @override
  bool operator ==(Object other) =>
      other is _DartResource &&
      other.path == path &&
      other.runtimeType == runtimeType;
  @override
  int get hashCode => Object.hash(path, runtimeType);
  @override
  bool get exists {
    provider.record(path);
    return base.exists;
  }

  @override
  afs.Folder get parent => provider.getFolder(base.parent.path);
  @override
  bool isOrContains(String path) => base.isOrContains(path);
  @override
  Uri toUri() => base.toUri();
  @override
  afs.Resource resolveSymbolicLinksSync() {
    provider.record(path);
    return provider.wrap(base.resolveSymbolicLinksSync());
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError(
    'Untraced analyzer resource operation ${i.memberName}: $path',
  );
}

class _DartFile extends _DartResource implements afs.File {
  _DartFile(super.provider, afs.File super.base);
  afs.File get file => base as afs.File;
  @override
  bool get exists {
    final exists = super.exists;
    // A present directory at a requested file path is not absent configuration.
    if (!exists &&
        FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      throw FileSystemException('Analyzer input is not a regular file', path);
    }
    return exists;
  }

  @override
  int get lengthSync {
    provider.record(path);
    return file.lengthSync;
  }

  @override
  int get modificationStamp {
    provider.record(path);
    return file.modificationStamp;
  }

  @override
  Uint8List readAsBytesSync() {
    provider.readPaths.add(path);
    // ResourceProvider.File is an interface, not proof of a regular OS file.
    // Reject devices/FIFOs/sockets before a potentially blocking synchronous open.
    // This checks the observed type; it is not an atomic guard against replacement.
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      provider.record(path);
      throw FileSystemException('Analyzer input is not a regular file', path);
    }
    try {
      final bytes = file.readAsBytesSync();
      provider.record(path, bytes);
      return bytes;
    } catch (error) {
      provider.record(path);
      rethrow;
    }
  }

  @override
  String readAsStringSync() => utf8.decode(readAsBytesSync());
}

class _DartFolder extends _DartResource implements afs.Folder {
  _DartFolder(super.provider, afs.Folder super.base);
  afs.Folder get folder => base as afs.Folder;
  @override
  bool get isRoot => folder.isRoot;
  @override
  bool contains(String path) => folder.contains(path);
  @override
  String canonicalizePath(String path) => folder.canonicalizePath(path);
  @override
  afs.Resource getChild(String relative) =>
      provider.getResource(canonicalizePath(relative));
  @override
  afs.File getFile(String relative) =>
      provider.getFile(canonicalizePath(relative));
  @override
  afs.Folder getFolder(String relative) =>
      provider.getFolder(canonicalizePath(relative));
  @override
  afs.File getChildAssumingFile(String relative) => getFile(relative);
  @override
  afs.Folder getChildAssumingFolder(String relative) => getFolder(relative);
  @override
  List<afs.Resource> getChildren() {
    try {
      provider.record(path);
      return folder.getChildren().map(provider.wrap).toList();
    } catch (error) {
      provider.failures.add('$path: $error');
      rethrow;
    }
  }
}
