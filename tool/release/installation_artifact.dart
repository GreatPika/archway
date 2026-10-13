// Controlled export of a trusted installation after transported acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';

import 'archive_input.dart';
import 'publish_directory.dart';
import 'tar_input.dart';

/// Verifies an extracted installation without changing or publishing it.
/// [compareModes] controls equality with expected modes; ordinary-source mode
/// validation still applies when equality is disabled.
Future<void> verifyInstallationDirectory(
  Directory root,
  ArchiveInventory expected, {
  required bool compareModes,
}) async {
  final (actual, _) = await _inventory(
    root,
    expected.files.keys.toSet(),
    maxArchiveBytes,
  );
  for (final entry in expected.files.entries) {
    final observed = actual.files[entry.key]!;
    if (observed.size != entry.value.size ||
        observed.sha256 != entry.value.sha256 ||
        (compareModes && observed.mode != entry.value.mode)) {
      throw FormatException('Installation identity differs: ${entry.key}');
    }
  }
}

Future<void> exportInstallation(
  Directory bundle,
  Directory destination,
  Set<String> expected,
  Map<String, Object?> provenance,
  Future<void> Function(Directory extracted, Directory workspace) verify, {
  int maxBytes = maxArchiveBytes,
}) async {
  if (maxBytes < 0 || maxBytes > maxArchiveBytes) {
    throw ArgumentError('Export limit must tighten the archive bound');
  }
  destination = destination.absolute;
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Artifact destination already exists',
      destination.path,
    );
  }
  final (inventory, sources) = await _inventory(bundle, expected, maxBytes);
  await destination.parent.create(recursive: true);
  final stage = await destination.parent.createTemp('.archway-artifact-');
  var published = false;
  try {
    if (!Platform.isWindows) posix.chmod(stage.path, '700');
    final archive = File(p.join(stage.path, 'installation.tar'));
    await archive.create(exclusive: true);
    final handle = archive.openSync(mode: FileMode.write);
    try {
      final writer = tarWritingSink(_BoundedOutput(handle, maxBytes));
      await writer.addStream(
        Stream.fromIterable(
          inventory.files.entries.map(
            (entry) => TarEntry(
              TarHeader(
                // Pinned defaults fix time/ownership; size avoids buffering.
                name: entry.key,
                mode: entry.value.mode,
                size: entry.value.size,
              ),
              _verifiedBytes(sources[entry.key]!, entry.value),
            ),
          ),
        ),
      );
      await writer.close();
    } finally {
      handle.closeSync();
    }
    final digest = await withArchiveInput(
      archive,
      (input) async {
        final workspace = await Directory.systemTemp.createTemp(
          'archway-transport café-',
        );
        try {
          if (!Platform.isWindows) posix.chmod(workspace.path, '700');
          final canonical = Directory(await workspace.resolveSymbolicLinks());
          await withTarExtraction(
            input,
            inventory,
            (extracted) => verify(extracted, canonical),
            temporaryParent: canonical,
          );
        } finally {
          await workspace.delete(recursive: true);
        }
        return input.sha256;
      },
      temporaryParent: stage,
      maxBytes: maxBytes,
    );
    final record = {
      ...provenance,
      'schema_version': 1,
      'files': {
        for (final entry in inventory.files.entries)
          entry.key: {
            'size': entry.value.size,
            'mode': entry.value.mode,
            'sha256': entry.value.sha256,
          },
      },
      'archive': {'name': 'installation.tar', 'sha256': digest},
    };
    final json = File(p.join(stage.path, 'provenance.json'));
    await json.create(exclusive: true);
    final output = json.openSync(mode: FileMode.write);
    try {
      final sink = _BoundedOutput(output, maxArchiveJsonBytes);
      final encoder = JsonUtf8Encoder('  ').startChunkedConversion(sink);
      encoder.add(_ordered(record));
      sink.add([10]);
      encoder.close();
    } finally {
      output.closeSync();
    }
    publishDirectory(stage, destination);
    published = true;
  } finally {
    if (!published) await stage.delete(recursive: true);
  }
}

Future<(ArchiveInventory, Map<String, File>)> _inventory(
  Directory bundle,
  Set<String> expected,
  int limit,
) async {
  if (expected.length > maxArchiveEntries)
    throw const FormatException('Too many source files');
  final directories = {'.'};
  for (final name in expected) {
    final parts = name.split('/');
    for (var i = 1; i < parts.length; i++)
      directories.add(parts.take(i).join('/'));
  }
  final identities = <String, ArchiveFileIdentity>{},
      sources = <String, File>{};
  var total = 0;
  Future<void> visit(FileSystemEntity entry) async {
    _rejectWindowsReparse(entry.path);
    final name = p
        .relative(entry.path, from: bundle.path)
        .split(p.separator)
        .join('/');
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (await entry.resolveSymbolicLinks() != entry.absolute.path)
      throw const FormatException('Aliased source');
    if (type == FileSystemEntityType.directory &&
        entry is Directory &&
        directories.contains(name)) {
      await for (final child in entry.list(followLinks: false)) {
        await visit(child);
      }
    } else if (type == FileSystemEntityType.file &&
        entry is File &&
        expected.contains(name) &&
        !identities.containsKey(name)) {
      final stat = await entry.stat();
      total += stat.size;
      if (stat.size > maxArchiveFileBytes || total > limit)
        throw const FormatException('Source exceeds byte bound');
      final digest = await sha256.bind(_sourceBytes(entry, stat.size)).first;
      identities[name] = (
        size: stat.size,
        mode: stat.mode & 0xfff,
        sha256: digest.toString(),
      );
      sources[name] = entry;
    } else {
      throw FormatException('Unexpected source entry: $name');
    }
  }

  await visit(bundle);
  if (identities.length != expected.length)
    throw const FormatException('Missing source files');
  final sorted = {
    for (final name in identities.keys.toList()..sort())
      name: identities[name]!,
  };
  return (
    ArchiveInventory.observedSourceRoundTrip(sorted, maxTotalBytes: limit),
    sources,
  );
}

final _windowsAttributes = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll').lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW')
    : null;

// Dart's no-follow type alone can report a junction as a directory. Reject all
// reparse tags before traversal/read; this is observation, not an atomic snapshot.
void _rejectWindowsReparse(String path) {
  if (!Platform.isWindows) return;
  final absolute = File(path).absolute.path;
  final extended = absolute.startsWith(r'\\?\')
      ? absolute
      : absolute.startsWith(r'\\')
      ? '\\\\?\\UNC\\${absolute.substring(2)}'
      : '\\\\?\\$absolute';
  using((arena) {
    final attributes = _windowsAttributes!(
      extended.toNativeUtf16(allocator: arena),
    );
    if (attributes == 0xffffffff) {
      throw FileSystemException('Cannot inspect source attributes', path);
    }
    if (attributes & 0x400 != 0) {
      throw const FormatException('Reparse source entry');
    }
  });
}

Stream<List<int>> _sourceBytes(File file, int expectedSize) async* {
  _rejectWindowsReparse(file.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.resolveSymbolicLinks() != file.absolute.path)
    throw const FormatException('Nonordinary source file');
  var size = 0;
  await for (final block in file.openRead()) {
    size += block.length;
    if (size > expectedSize) throw const FormatException('Source grew');
    yield block;
  }
  if (size != expectedSize) throw const FormatException('Source shrank');
}

Stream<List<int>> _verifiedBytes(
  File file,
  ArchiveFileIdentity identity,
) async* {
  final digest = _Digest();
  final sink = sha256.startChunkedConversion(digest);
  try {
    await for (final block in _sourceBytes(file, identity.size)) {
      sink.add(block);
      yield block;
    }
  } finally {
    sink.close();
  }
  if (digest.value != identity.sha256)
    throw const FormatException('Source bytes changed');
}

Object? _ordered(Object? value) => switch (value) {
  Map<String, Object?>() => {
    for (final key in value.keys.toList()..sort()) key: _ordered(value[key]),
  },
  List() => value.map(_ordered).toList(),
  _ => value,
};

final class _Digest implements Sink<Digest> {
  String? value;
  @override
  void add(Digest digest) {
    value = digest.toString();
  }

  @override
  void close() {}
}

// The exporter owns the prepared handle; closing a codec cannot close it twice.
final class _BoundedOutput implements StreamSink<List<int>> {
  _BoundedOutput(this.file, this.limit);
  final RandomAccessFile file;
  final int limit;
  final _closed = Completer<void>();
  var length = 0;
  @override
  void add(List<int> bytes) {
    length += bytes.length;
    if (length > limit)
      throw const FormatException('Encoded artifact exceeds bound');
    file.writeFromSync(bytes);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      add(bytes);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current);
  @override
  Future<void> close() {
    if (!_closed.isCompleted) _closed.complete();
    return done;
  }

  @override
  Future<void> get done => _closed.future;
}
