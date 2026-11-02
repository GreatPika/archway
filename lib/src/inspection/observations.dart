import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../native/physical_paths.dart';
import '../plan/repository_path.dart';
import 'physical_paths.dart';
import 'input_observation.dart';

String inventoryEntryKind(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.file => 'file',
  FileSystemEntityType.directory => 'directory',
  FileSystemEntityType.link => 'symlink',
  _ => 'other',
};

// Directory.list distinguishes directories/links, but represents other OS
// entries (including FIFOs) through File. Do not infer regular-file type there.
bool listedEntryMatches(FileSystemEntity entry, FileSystemEntityType type) {
  if (entry is Directory) return type == FileSystemEntityType.directory;
  if (entry is Link) return type == FileSystemEntityType.link;
  return type != FileSystemEntityType.directory &&
      type != FileSystemEntityType.link &&
      type != FileSystemEntityType.notFound;
}

// Dart's Windows directory lister does not add the extended-length prefix.
// Keep it confined to enumeration; all observations retain the original path.
Stream<FileSystemEntity> observedDirectoryEntries(String native) async* {
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

Future<InputObservation> observeInput(
  String native,
  String role, [
  String? project,
]) async {
  final observed = fileUri(native);
  final route = PhysicalPaths.trace(native);
  final hops = route.hops;
  final type = await FileSystemEntity.type(native);
  if (type == FileSystemEntityType.notFound) {
    if (await FileSystemEntity.type(native, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('Cannot resolve observed alias', native);
    }
    return InputObservation(
      'absent',
      observed,
      null,
      null,
      role,
      project,
      hops,
    );
  }
  (Zone.current[#archwayBeforeObservationCanonical] as void Function(String)?)
      ?.call(native);
  final canonical = fileUri(await File(native).resolveSymbolicLinks());
  if (fileUri(route.path) != canonical) {
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
    if (fileUri(await File(route.path).resolveSymbolicLinks()) != canonical) {
      throw FileSystemException('Physical pathname identity changed', native);
    }
    unchanged();
  }
  if (type == FileSystemEntityType.file) {
    return InputObservation(
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
    await for (final entry in observedDirectoryEntries(native)) {
      (Zone.current[#archwayBeforeInventoryEntryStat] as void Function(String)?)
          ?.call(entry.path);
      final kind = await FileSystemEntity.type(entry.path, followLinks: false);
      final name = p.basename(entry.path);
      if (!listedEntryMatches(entry, kind) ||
          !names.add(name) ||
          utf8.decode(utf8.encode('x$name')) != 'x$name') {
        throw FileSystemException(
          'Directory entry is unrepresentable or changed',
          native,
        );
      }
      entries.add([name, inventoryEntryKind(kind)]);
    }
    entries.sort((a, b) => comparePlanText(a[0], b[0]));
    return InputObservation(
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

class ObservedInputs {
  final String root;
  final observations = <InputObservation>[];
  final changed = <String>{};
  final conflictedProjects = <String>{};
  bool rechecked = false;
  ObservedInputs(this.root);

  void add(InputObservation item) {
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
        final fresh = await observeInput(
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
    final relative = inputPhysicalPath(
      repositoryRelativePath(root, PhysicalPaths.fromFileUri(Uri.parse(uri))),
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
