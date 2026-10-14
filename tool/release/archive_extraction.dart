import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'publish_directory.dart';

/// A competing destination exists; the caller must validate it before use.
final class ArchiveDestinationExists extends FileSystemException {
  const ArchiveDestinationExists(String path, [OSError? error])
    : super('Archive destination already exists', path, error);
}

/// Owns a private extraction until inspection ends or publication transfers it.
/// The codec must admit all metadata before calling this scope and verify all
/// bytes before completing [extract]. [publishTo] selects its own sibling stage;
/// otherwise [temporaryParent] holds the short-lived inspection directory.
/// A publication parent must already exist and its path must be canonical.
Future<T> withArchiveExtraction<T>(
  Directory temporaryParent,
  Future<void> Function(Directory directory) extract,
  Future<T> Function(Directory directory) inspect, {
  Directory? publishTo,
}) async {
  if (publishTo != null) {
    publishTo = publishTo.absolute;
    final path = publishTo.path, parent = publishTo.parent;
    if (path.contains('\x00') ||
        utf8.decode(utf8.encode(path)) != path ||
        p.normalize(path) != path ||
        await FileSystemEntity.type(parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await parent.resolveSymbolicLinks() != parent.path) {
      throw const FormatException('Expected canonical publication destination');
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ArchiveDestinationExists(path);
    }
  }
  final directory = await (publishTo?.parent ?? temporaryParent).createTemp(
    '.archway-extract-',
  );
  var published = false;
  try {
    setArchiveMode(directory.path, 0x1c0);
    final canonical = Directory(await directory.resolveSymbolicLinks());
    await extract(canonical);
    final result = await inspect(canonical);
    if (publishTo != null) {
      try {
        publishDirectory(canonical, publishTo);
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (Platform.isWindows ? code == 80 || code == 183 : code == 17) {
          throw ArchiveDestinationExists(publishTo.path, error.osError);
        }
        rethrow;
      }
      published = true;
    }
    return result;
  } finally {
    if (!published) await directory.delete(recursive: true);
  }
}

void setArchiveMode(String path, int mode) {
  // Windows checks archive-mode provenance but cannot reproduce Unix modes.
  if (!Platform.isWindows) posix.chmod(path, mode.toRadixString(8));
}
