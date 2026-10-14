// Read-only final admission against an independently regenerated canonical stage.
import 'dart:io';

import '../release/archive_input.dart';
import '../validation/json_values.dart';
import 'installed_identity.dart';
import 'packed_inventory.dart';

Future<Map<String, Object?>> verifyNpmPackedCandidate(
  Directory canonicalStage,
  Directory packed, {
  required String expectedCommit,
  required bool registryReady,
}) async {
  final stage = await admitNpmStage(canonicalStage);
  return withNpmPackedCandidate(
    packed,
    expectedCommit: expectedCommit,
    registryReady: registryReady,
    inspect: (archive, receipt) async {
      if (!sameJson(receipt['source'], stage.receipt['source']) ||
          receipt['version'] != stage.receipt['version'] ||
          receipt['registry_ready'] != stage.receipt['registry_ready'] ||
          receipt['descriptor_sha256'] != stage.receipt['descriptor_sha256'] ||
          receipt['stage_inventory_sha256'] != stage.inventorySha256) {
        throw const FormatException(
          'Packed npm candidate differs from canonical stage',
        );
      }
      await withArchiveInput(
        archive,
        (input) => verifyNpmArchiveInput(input, stage.inventory),
        expected: (
          size: receipt['compressed_bytes'] as int,
          sha256: receipt['sha256'] as String,
        ),
      );
      return receipt;
    },
  );
}
