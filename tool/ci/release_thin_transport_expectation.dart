// Explicit thin-transport admission; the legacy release reader stays separate.
import 'dart:convert';

import '../pub/upload.dart';
import '../release/archive_input.dart';
import 'pub_stage_transport.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

Map<String, dynamic> expectedThinPubTransport(
  String text,
  Map<String, Object?> source,
  String runId,
  String runAttempt, {
  required bool registryReady,
}) {
  requireReceipt(
    utf8.encode(text).length <= maxArchiveJsonBytes,
    'Expected thin transport exceeds bound',
  );
  final value = receiptObject(decodeEvidenceJson(text));
  requireReceipt(
    exactReceipt(value['source'], source),
    'Thin transport source differs from current checkout',
  );
  admitPubTransportRecord(
    value,
    source['commit'] as String,
    runId,
    runAttempt,
    registryReady,
  );
  if (registryReady) {
    final upload = receiptObject(value['upload_archive']);
    bool bounded(Object? value, int lower, int upper) =>
        value is int && value >= lower && value < upper;
    requireReceipt(
      upload.length == 4 &&
          upload.keys.toSet().containsAll([
            'sha256',
            'size',
            'unpacked_bytes',
            'files',
          ]) &&
          upload['sha256'] is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(upload['sha256'] as String) &&
          bounded(upload['size'], 1, pubCompressedLimit) &&
          bounded(upload['unpacked_bytes'], 0, pubExpandedLimit) &&
          bounded(upload['files'], 1, maxArchiveEntries),
      'Invalid expected thin pub upload identity',
    );
  }
  return value;
}
