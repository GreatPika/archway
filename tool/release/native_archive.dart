// Developer-only native bundle verification; caller policy stays with callers.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'archive_input.dart';
import 'gzip_input.dart';
import 'strict_json.dart';
import 'tar_input.dart';
import 'zip_input.dart';

enum NativeArchiveFormat { tarGzip, zip }

/// Original identities and manifest, returned only after complete verification.
final class VerifiedNativeArchive {
  VerifiedNativeArchive._({
    required List<int> manifestBytes,
    required Map<String, Object?> manifest,
    required this.completeArchiveInventory,
    required this.archiveSize,
    required this.archiveSha256,
    required this.manifestSha256,
  }) : manifestBytes = List.unmodifiable(manifestBytes),
       manifest = _freeze(manifest) as Map<String, Object?>;

  final List<int> manifestBytes;
  final Map<String, Object?> manifest;
  final ArchiveInventory completeArchiveInventory;
  final int archiveSize;
  final String archiveSha256;
  final String manifestSha256;
}

/// Verifies bytes and inventory; does not decide source, target or version policy.
/// The original is copied once and is never reopened by an archive decoder.
Future<VerifiedNativeArchive> verifyNativeArchive(
  File source, {
  required NativeArchiveFormat format,
  Directory? temporaryParent,
  ({int size, String sha256})? expected,
}) => withArchiveInput(
  source,
  (snapshot) async {
    Future<VerifiedNativeArchive> verify(ArchiveInput input) async {
      final bytes = format == NativeArchiveFormat.zip
          ? await readZipManifest(input)
          : await readTarManifest(input);
      final value = decodeEvidenceJson(utf8.decode(bytes));
      if (value is! Map<String, Object?>) {
        throw const FormatException('Native manifest must be an object');
      }
      final files = value['files'];
      if (files is! Map<String, Object?> ||
          files.isEmpty ||
          files.length >= maxArchiveEntries ||
          files.containsKey('manifest.json')) {
        throw const FormatException('Invalid native file inventory');
      }
      final identities = <String, ArchiveFileIdentity>{};
      for (final entry in files.entries) {
        final identity = entry.value;
        if (identity is! Map<String, Object?> ||
            identity.length != 3 ||
            identity['size'] is! int ||
            identity['mode'] is! int ||
            identity['sha256'] is! String) {
          throw const FormatException('Invalid native manifest entry');
        }
        identities[entry.key] = (
          size: identity['size'] as int,
          mode: identity['mode'] as int,
          sha256: identity['sha256'] as String,
        );
      }
      final manifestSha256 = crypto.sha256.convert(bytes).toString();
      identities['manifest.json'] = (
        size: bytes.length,
        mode: 0x1a4,
        sha256: manifestSha256,
      );
      final inventory = ArchiveInventory(identities);
      if (format == NativeArchiveFormat.zip) {
        await verifyZipInput(input, inventory);
      } else {
        await verifyTarInput(input, inventory);
      }
      return VerifiedNativeArchive._(
        manifestBytes: bytes,
        manifest: value,
        completeArchiveInventory: inventory,
        archiveSize: snapshot.size,
        archiveSha256: snapshot.sha256,
        manifestSha256: manifestSha256,
      );
    }

    if (format == NativeArchiveFormat.zip) return verify(snapshot);
    return withGzipSnapshot(
      snapshot,
      (expanded) =>
          withArchiveInput(expanded, verify, temporaryParent: temporaryParent),
    );
  },
  temporaryParent: temporaryParent,
  expected: expected,
);

// JSON has only maps, arrays and scalar leaves; retain none of its mutable lists.
Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key, _freeze(item))),
  ),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
