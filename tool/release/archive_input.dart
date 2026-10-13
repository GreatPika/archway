// Developer-only inputs for native archive verification and production.
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

const maxArchiveBytes = 512 * 1024 * 1024;
const maxArchiveFileBytes = 128 * 1024 * 1024;
const maxArchiveEntries = 4096;
// Metadata callers must select this tighter snapshot bound before JSON parsing.
const maxArchiveJsonBytes = 2 * 1024 * 1024;

/// Valid only during the callback supplied to [withArchiveInput].
final class ArchiveInput {
  ArchiveInput._(this.file, this.size, this.sha256);

  final File file;
  final int size;
  final String sha256;
}

/// Copies an ordinary, non-aliased input into a unique owned directory.
/// The absolute input spelling must already be canonical.
/// No decoder or caller ever needs to reopen the original input afterward.
Future<T> withArchiveInput<T>(
  File source,
  Future<T> Function(ArchiveInput input) inspect, {
  Directory? temporaryParent,
  ({int size, String sha256})? expected,
  int maxBytes = maxArchiveBytes,
}) async {
  if (maxBytes < 0 || maxBytes > maxArchiveBytes) {
    throw ArgumentError.value(
      maxBytes,
      'maxBytes',
      'Must tighten the archive bound',
    );
  }
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await source.resolveSymbolicLinks() != source.absolute.path) {
    throw const FormatException('Aliased or nonregular archive input');
  }
  final stat = await source.stat();
  if (stat.size > maxBytes)
    throw const FormatException('Archive input exceeds bound');
  final directory = await (temporaryParent ?? Directory.systemTemp).createTemp(
    '.archway-archive-',
  );
  try {
    if (!Platform.isWindows) posix.chmod(directory.path, '700');
    final snapshot = File(
      p.join(await directory.resolveSymbolicLinks(), 'input'),
    );
    await snapshot.create(exclusive: true);
    final output = await snapshot.open(mode: FileMode.write);
    var size = 0;
    try {
      await for (final bytes in source.openRead()) {
        size += bytes.length;
        if (size > maxBytes)
          throw const FormatException('Archive input exceeds bound');
        await output.writeFrom(bytes);
      }
    } finally {
      await output.close();
    }
    final digest = await crypto.sha256.bind(snapshot.openRead()).first;
    if (expected != null &&
        (size != expected.size || digest.toString() != expected.sha256)) {
      throw const FormatException('Archive input differs from pinned identity');
    }
    return await inspect(ArchiveInput._(snapshot, size, digest.toString()));
  } finally {
    await directory.delete(recursive: true);
  }
}

typedef ArchiveFileIdentity = ({int size, int mode, String sha256});
typedef ArchiveMember = ({String name, int size, int mode});

/// One immutable expected inventory shared by archive preflight and byte checks.
final class ArchiveInventory {
  ArchiveInventory(
    Map<String, ArchiveFileIdentity> files, {
    int maxFileBytes = maxArchiveFileBytes,
    int maxTotalBytes = maxArchiveBytes,
    int maxEntries = maxArchiveEntries,
  }) : this._(files, maxFileBytes, maxTotalBytes, maxEntries, false);

  /// Only for round-tripping observed trusted source permissions, not imports.
  ArchiveInventory.observedSourceRoundTrip(
    Map<String, ArchiveFileIdentity> files, {
    int maxTotalBytes = maxArchiveBytes,
  }) : this._(
         files,
         maxArchiveFileBytes,
         maxTotalBytes,
         maxArchiveEntries,
         true,
       );

  ArchiveInventory._(
    Map<String, ArchiveFileIdentity> files,
    int maxFileBytes,
    int maxTotalBytes,
    int maxEntries,
    bool observedSource,
  ) : files = Map.unmodifiable(files) {
    if (maxFileBytes < 0 ||
        maxFileBytes > maxArchiveFileBytes ||
        maxTotalBytes < 0 ||
        maxTotalBytes > maxArchiveBytes ||
        maxEntries < 0 ||
        maxEntries > maxArchiveEntries) {
      throw ArgumentError('Caller limits must tighten archive bounds');
    }
    if (files.length > maxEntries) {
      throw const FormatException('Archive inventory exceeds entry bound');
    }
    var total = 0;
    for (final entry in files.values) {
      // Imports retain known producer modes; observed sources allow ordinary bits.
      final modeAllowed = observedSource
          ? entry.mode >= 0 && entry.mode <= 0x1ff
          : {0x1a4, 0x1ed, 0x1b6, 0x1ff}.contains(entry.mode);
      if (!modeAllowed ||
          entry.sha256.length != 64 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.sha256)) {
        throw const FormatException('Invalid archive file identity');
      }
      total += entry.size;
      if (entry.size < 0 ||
          entry.size > maxFileBytes ||
          total > maxTotalBytes) {
        throw const FormatException('Archive inventory exceeds byte bound');
      }
    }
    final aliases = <String, String>{};
    final fileKeys = files.keys.map(_pathKey).toSet();
    for (final name in files.keys) {
      _checkName(name);
      final parts = name.split('/');
      for (var i = 1; i <= parts.length; i++) {
        final prefix = parts.take(i).join('/');
        final key = _pathKey(prefix);
        final previous = aliases[key];
        if ((previous != null && previous != prefix) ||
            (i < parts.length && fileKeys.contains(key))) {
          throw FormatException('Aliased or colliding archive path: $name');
        }
        aliases[key] = prefix;
      }
    }
  }

  final Map<String, ArchiveFileIdentity> files;

  void checkMembers(Iterable<ArchiveMember> members) {
    final seen = <String>{};
    for (final member in members) {
      final expected = files[member.name];
      if (expected == null ||
          !seen.add(member.name) ||
          member.size != expected.size ||
          member.mode != expected.mode) {
        throw FormatException('Unexpected archive member: ${member.name}');
      }
    }
    if (seen.length != files.length) {
      throw const FormatException('Missing archive members');
    }
  }
}

void _checkName(String name) {
  final parts = name.split('/');
  if (name.isEmpty ||
      name.contains('\\') ||
      name.contains(':') ||
      name.codeUnits.any((unit) => unit < 32) ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(
              r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw FormatException('Noncanonical archive path: $name');
  }
}

// Portable alias policy: NFC plus Dart's default simple-case closure, including
// final sigma. This does not implement full Unicode or filesystem case folding.
String _pathKey(String name) =>
    unicode.nfc(unicode.nfc(name).toLowerCase().toUpperCase().toLowerCase());
