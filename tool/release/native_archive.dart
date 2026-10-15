// Developer-only native bundle verification; caller policy stays with callers.
import 'dart:io';

import 'archive_input.dart';
import 'gzip_input.dart';
import 'native_manifest.dart';
import 'tar_input.dart';
import 'zip_input.dart';

enum NativeArchiveFormat { tarGzip, zip }

/// Original identities and manifest, returned only after complete verification.
final class VerifiedNativeArchive {
  VerifiedNativeArchive._({
    required NativeManifest parsed,
    required this.archiveSize,
    required this.archiveSha256,
  }) : manifestBytes = parsed.manifestBytes,
       manifest = parsed.manifest,
       completeArchiveInventory = parsed.completeArchiveInventory,
       manifestSha256 = parsed.manifestSha256;

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
      final parsed = parseNativeManifest(bytes);
      final inventory = parsed.completeArchiveInventory;
      if (format == NativeArchiveFormat.zip) {
        await verifyZipInput(input, inventory);
      } else {
        await verifyTarInput(input, inventory);
      }
      return VerifiedNativeArchive._(
        parsed: parsed,
        archiveSize: snapshot.size,
        archiveSha256: snapshot.sha256,
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
