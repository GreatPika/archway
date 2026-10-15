// The SDK upload is a separate directory-admitting dialect, never a native TAR.
import 'dart:io';

import '../release/archive_input.dart';
import '../release/gzip_input.dart';
import '../release/tar_input.dart';

const pubCompressedLimit = 100000000;
const pubExpandedLimit = 256000000;

/// Inspects exact staged file identities; optional extraction is no-clobber.
/// Limits are conservative candidate budgets, not pub.dev availability claims.
Future<Map<String, Object>> inspectPubUpload(
  File archive,
  ArchiveInventory files, {
  ({int size, String sha256})? expected,
  Directory? publishTo,
}) => withArchiveInput(
  archive,
  (compressed) => withGzipSnapshot(
    compressed,
    (expanded) => withArchiveInput(expanded, (tar) async {
      if (publishTo == null) {
        await verifyTarInput(tar, files, dialect: TarDialect.pubUpload);
      } else {
        await withTarExtraction(
          tar,
          files,
          (_) async {},
          dialect: TarDialect.pubUpload,
          publishTo: publishTo,
        );
      }
      return {
        'sha256': compressed.sha256,
        'size': compressed.size,
        'unpacked_bytes': files.files.values.fold<int>(
          0,
          (sum, file) => sum + file.size,
        ),
        'files': files.files.length,
      };
    }, maxBytes: pubExpandedLimit - 1),
    maxExpandedBytes: pubExpandedLimit - 1,
  ),
  expected: expected,
  maxBytes: pubCompressedLimit - 1,
);
