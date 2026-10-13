part of 'inspection.dart';

class _Observation {
  final String kind;
  final String observed;
  final String? canonical;
  final String? hash;
  final String role;
  final String? project;
  final List<Map<String, String>> symlinkHops;
  _Observation(
    this.kind,
    this.observed,
    this.canonical,
    this.hash,
    this.role, [
    this.project,
    List<Map<String, String>> symlinkHops = const [],
  ]) : symlinkHops = List.unmodifiable(
         symlinkHops.map((hop) => Map<String, String>.unmodifiable(hop)),
       );
  String get contentIdentity => jsonEncode([kind, canonical, hash]);
  String get identity => jsonEncode([kind, canonical, hash, symlinkHops]);
}

String _uri(String native) => File(native).uri.toString();
String? _relative(String root, String native) {
  if (native == root) return './';
  if (!p.isWithin(root, native)) return null;
  return p.relative(native, from: root).split(p.separator).join('/');
}

String _inventoryKind(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.file => 'file',
  FileSystemEntityType.directory => 'directory',
  FileSystemEntityType.link => 'symlink',
  _ => 'other',
};

// Directory.list distinguishes directories/links, but represents other OS
// entries (including FIFOs) through File. Do not infer regular-file type there.
bool _listedEntryMatches(FileSystemEntity entry, FileSystemEntityType type) {
  if (entry is Directory) return type == FileSystemEntityType.directory;
  if (entry is Link) return type == FileSystemEntityType.link;
  return type != FileSystemEntityType.directory &&
      type != FileSystemEntityType.link &&
      type != FileSystemEntityType.notFound;
}

// Dart's Windows directory lister does not add the extended-length prefix.
// Keep it confined to enumeration; all observations retain the original path.
Stream<FileSystemEntity> _directoryEntries(String native) async* {
  var listing = native;
  if (Platform.isWindows) {
    final path = native.replaceAll('/', r'\');
    final root = p.windows.rootPrefix(path);
    final ordinaryDrive = RegExp(r'^[A-Za-z]:\\$').hasMatch(root);
    final ordinaryUnc = RegExp(r'^\\\\[^\\?\.][^\\]*\\[^\\]+\\?$')
        .hasMatch(root);
    final parts = path.substring(root.length).split(r'\');
    if ((ordinaryDrive || ordinaryUnc) &&
        parts.every(
          (part) =>
              part.isNotEmpty && !part.endsWith('.') && !part.endsWith(' '),
        )) {
      listing = ordinaryDrive
          ? '\\\\?\\$path'
          : '\\\\?\\UNC\\${path.substring(2)}';
    }
  }
  try {
    await for (final entry in Directory(listing).list(followLinks: false)) {
      if (listing == native) {
        yield entry;
      } else {
        final path = p.join(native, p.basename(entry.path));
        yield switch (entry) {
          Directory() => Directory(path),
          Link() => Link(path),
          _ => File(path),
        };
      }
    }
  } on FileSystemException catch (error) {
    if (listing == native) rethrow;
    throw FileSystemException(error.message, native, error.osError);
  }
}

Future<_Observation> _observe(
  String native,
  String role, [
  String? project,
]) async {
  final observed = _uri(native);
  final route = PhysicalPaths.trace(native);
  final hops = route.hops;
  final type = await FileSystemEntity.type(native);
  if (type == FileSystemEntityType.notFound) {
    if (await FileSystemEntity.type(native, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('Cannot resolve observed alias', native);
    }
    return _Observation('absent', observed, null, null, role, project, hops);
  }
  (Zone.current[#archwayBeforeObservationCanonical] as void Function(String)?)
      ?.call(native);
  final canonical = _uri(await File(native).resolveSymbolicLinks());
  if (_uri(route.path) != canonical) {
    // Permit resolver entry spelling, not an unrecorded alias. Both the original
    // route and its independently expanded endpoint must stay hop-stable.
    void unchanged() {
      final endpoint = PhysicalPaths.trace(route.path);
      final fresh = PhysicalPaths.trace(native);
      if (endpoint.hops.isNotEmpty ||
          endpoint.path != route.path ||
          fresh.path != route.path ||
          jsonEncode(fresh.hops) != jsonEncode(hops)) {
        throw FileSystemException(
          'Physical route changed during canonicalization',
          native,
        );
      }
    }

    unchanged();
    if (_uri(await File(route.path).resolveSymbolicLinks()) != canonical) {
      throw FileSystemException('Physical pathname identity changed', native);
    }
    unchanged();
  }
  if (type == FileSystemEntityType.file) {
    return _Observation(
      'file',
      observed,
      canonical,
      sha256.convert(await File(native).readAsBytes()).toString(),
      role,
      project,
      hops,
    );
  }
  if (type == FileSystemEntityType.directory) {
    final entries = <List<String>>[];
    final names = <String>{};
    await for (final entry in _directoryEntries(native)) {
      (Zone.current[#archwayBeforeInventoryEntryStat] as void Function(String)?)
          ?.call(entry.path);
      final kind = await FileSystemEntity.type(entry.path, followLinks: false);
      final name = p.basename(entry.path);
      if (!_listedEntryMatches(entry, kind) ||
          !names.add(name) ||
          utf8.decode(utf8.encode('x$name')) != 'x$name') {
        throw FileSystemException(
          'Directory entry is unrepresentable or changed',
          native,
        );
      }
      entries.add([name, _inventoryKind(kind)]);
    }
    entries.sort((a, b) => comparePlanText(a[0], b[0]));
    return _Observation(
      'directory',
      observed,
      canonical,
      sha256.convert(utf8.encode(jsonEncode(entries))).toString(),
      role,
      project,
      hops,
    );
  }
  throw FileSystemException('Unsupported filesystem input', native);
}

class _Inputs {
  final String root;
  final observations = <_Observation>[];
  final changed = <String>{};
  final conflictedProjects = <String>{};
  bool rechecked = false;
  _Inputs(this.root);

  void add(_Observation item) {
    final conflicts = observations
        .followedBy([item])
        .where(
          (other) =>
              (other.observed == item.observed &&
                  other.identity != item.identity) ||
              (other.canonical != null &&
                  other.canonical == item.canonical &&
                  other.contentIdentity != item.contentIdentity) ||
              other.symlinkHops.any(
                (a) => item.symlinkHops.any(
                  (b) =>
                      a['observed_uri'] == b['observed_uri'] &&
                      a['target'] != b['target'],
                ),
              ),
        );
    for (final other in conflicts) {
      changed.add(item.observed);
      changed.add(other.observed);
      if (other.project != null) conflictedProjects.add(other.project!);
      if (item.project != null) conflictedProjects.add(item.project!);
    }
    observations.add(item);
  }

  Future<void> recheck() async {
    Object? failure;
    for (final old in observations) {
      // Hop-only helper evidence must not depend on redundant standalone input
      // rows, or on successful traversal through an earlier hop in the route.
      for (final hop in old.symlinkHops) {
        try {
          final path = PhysicalPaths.fromFileUri(
            Uri.parse(hop['observed_uri']!),
          );
          if (FileSystemEntity.typeSync(path, followLinks: false) !=
                  FileSystemEntityType.link ||
              PhysicalPaths.readLinkTarget(path) != hop['target']) {
            changed.add(old.observed);
          }
        } catch (error) {
          failure ??= error;
        }
      }
      try {
        final fresh = await _observe(
          PhysicalPaths.fromFileUri(Uri.parse(old.observed)),
          old.role,
        );
        if (fresh.identity != old.identity) changed.add(old.observed);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
    rechecked = true;
  }

  Map<String, Object?> location(String uri) {
    final relative = _inputPhysicalPath(
      _relative(root, PhysicalPaths.fromFileUri(Uri.parse(uri))),
    );
    return relative == null
        ? {'kind': 'external', 'canonical_file_uri': uri}
        : {'kind': 'repository', 'path': relative};
  }

  Map<String, Object?> toJson() {
    final baselines = <String, Map<String, Object?>>{};
    final aliases = <String, Map<String, Object?>>{};
    for (final item in observations) {
      final loc = location(item.canonical ?? item.observed);
      final kind = item.kind == 'directory' ? 'inventory' : item.role;
      baselines.putIfAbsent(
        '$kind|${jsonEncode(loc)}',
        () => {
          'kind': kind,
          'location': loc,
          'presence': item.kind == 'absent' ? 'absent' : 'present',
          'hash': item.hash == null ? null : 'sha256:${item.hash}',
        },
      );
      if (item.canonical != null && item.observed != item.canonical) {
        aliases.putIfAbsent(
          item.observed,
          () => {
            'observed_file_uri': item.observed,
            'canonical_file_uri': item.canonical,
          },
        );
      }
    }
    final keys = baselines.keys.toList()..sort(comparePlanText);
    final aliasKeys = aliases.keys.toList()..sort(comparePlanText);
    final changedKeys = changed.toList()..sort(comparePlanText);
    return {
      'algorithm': 'sha256',
      'atomic_snapshot': false,
      'inputs': keys.map((k) => baselines[k]).toList(),
      'rechecked': rechecked,
      'changed_inputs': changedKeys.map(location).toList(),
      'aliases': aliasKeys.map((k) => aliases[k]).toList(),
    };
  }
}

String? _language(String file) {
  final ext = p.extension(file);
  if ({'.ts', '.tsx', '.mts', '.cts'}.contains(ext)) return 'typescript';
  if (ext == '.dart') return 'dart';
  if ({'.js', '.jsx', '.mjs', '.cjs', '.vue', '.svelte'}.contains(ext)) {
    return 'unsupported';
  }
  return null;
}

Future<List<String>> _corpus(
  Plan plan,
  _Inputs inputs,
  List<Map<String, Object?>> unknowns,
  List<Map<String, Object?>> warnings,
) async {
  final files = <String>{};
  final visited = <String>{};
  bool excluded(String path) =>
      plan.owner(path).ownership == 'excluded' ||
      plan.exclude.contains('$path/');
  Future<void> visit(String relative, {bool descend = true}) async {
    if (!visited.add('$relative|$descend')) return;
    final native = p.join(inputs.root, relative == './' ? '' : relative);
    try {
      if (normalizeRepositoryPath(relative) != relative ||
          unicode.nfc(relative) != relative) {
        throw const FormatException('Noncanonical source spelling.');
      }
      if (excluded(relative)) return;
      final type = await FileSystemEntity.type(native, followLinks: false);
      if (type == FileSystemEntityType.link) {
        unknowns.add(
          inspectionDiagnostic(
            'SOURCE_SYMLINK',
            'Selected source paths must not traverse a symlink.',
            path: relative,
          ),
        );
        return;
      }
      if (type == FileSystemEntityType.directory) {
        inputs.add(await _observe(native, 'inventory'));
        if (!descend) return;
        final entries = await _directoryEntries(native).toList();
        entries.sort((a, b) => comparePlanText(a.path, b.path));
        for (final entry in entries) {
          await visit(_relative(inputs.root, entry.path)!);
        }
      } else if (type == FileSystemEntityType.file) {
        if (_language(relative) != null) {
          files.add(relative);
          inputs.add(await _observe(native, 'source'));
        } else if (plan.scope.contains(relative)) {
          warnings.add(
            inspectionDiagnostic(
              'UNSUPPORTED_SCOPE_FILE',
              'The explicitly selected file is not a recognized source kind.',
              path: relative,
              severity: 'warning',
            ),
          );
        }
      } else if (type == FileSystemEntityType.notFound) {
        inputs.add(await _observe(native, 'resolution'));
      } else {
        throw FileSystemException(
          'Selected path is not a regular file.',
          native,
        );
      }
    } catch (error) {
      unknowns.add(
        inspectionDiagnostic(
          'CORPUS_ENUMERATION_FAILED',
          'Cannot enumerate selected input $relative: $error',
          path: _publicPhysicalPath(relative),
        ),
      );
    }
  }

  for (final scope in plan.scope) {
    if (excluded(scope)) continue;
    // Inventory each selected prefix before accepting its physical spelling.
    // NFC equality cannot silently substitute a different directory entry.
    var prefix = inputs.root;
    String? refusal;
    try {
      for (final segment
          in scope.split('/').where((s) => s.isNotEmpty && s != '.')) {
        if (await FileSystemEntity.type(prefix, followLinks: false) !=
            FileSystemEntityType.directory)
          break;
        inputs.add(await _observe(prefix, 'inventory'));
        final entries = await _directoryEntries(prefix).toList();
        final matches = entries.where(
          (entry) => unicode.nfc(p.basename(entry.path)) == segment,
        );
        if (matches.length > 1 ||
            (matches.isNotEmpty &&
                p.basename(matches.single.path) != segment)) {
          refusal = 'PHYSICAL_PATH_AMBIGUOUS';
          break;
        }
        prefix = p.join(prefix, segment);
        final type = await FileSystemEntity.type(prefix, followLinks: false);
        if (type == FileSystemEntityType.link) {
          refusal = 'SOURCE_SYMLINK';
          break;
        }
        if (type != FileSystemEntityType.notFound && matches.isEmpty) {
          refusal = 'PHYSICAL_PATH_AMBIGUOUS';
          break;
        }
      }
      if (refusal != null) {
        unknowns.add(
          inspectionDiagnostic(
            refusal,
            'Selected scope has an unsafe physical identity.',
            path: scope,
          ),
        );
      } else {
        await visit(
          scope == './' ? './' : scope.replaceFirst(RegExp(r'/$'), ''),
          descend: scope.endsWith('/'),
        );
      }
    } catch (error) {
      unknowns.add(
        inspectionDiagnostic(
          'CORPUS_ENUMERATION_FAILED',
          'Cannot inspect selected prefix: $error',
          path: scope,
        ),
      );
    }
  }
  return files.toList()..sort(comparePlanText);
}
