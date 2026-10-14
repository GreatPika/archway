// Parse caller-bound registry transport identity without opening an archive.
import 'dart:convert';

import '../release/archive_input.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

Map<String, dynamic> expectedPubTransport(
  String text,
  Map<String, Object?> source,
  String runId,
  String runAttempt, {
  required bool registryReady,
}) {
  requireReceipt(
    utf8.encode(text).length <= 4096,
    'Expected transport record exceeds bound',
  );
  final value = receiptObject(decodeEvidenceJson(text));
  final keys = {
    'schema_version',
    'source',
    'file_set_sha256',
    'archive',
    'run_id',
    'run_attempt',
    if (registryReady) ...['registry_ready', 'upload_archive'],
  };
  requireReceipt(
    value.length == keys.length &&
        keys.every(value.containsKey) &&
        value['schema_version'] is int &&
        value['schema_version'] == (registryReady ? 2 : 1),
    'Invalid expected transport record',
  );
  bool hash(Object? value, int width) =>
      value is String && RegExp('^[0-9a-f]{$width}\$').hasMatch(value);
  bool between(Object? value, int lower, int upper) =>
      value is int && value >= lower && value <= upper;
  if (registryReady) {
    final upload = receiptObject(value['upload_archive']);
    requireReceipt(
      value['registry_ready'] == true &&
          upload.length == 4 &&
          {
            'sha256',
            'size',
            'unpacked_bytes',
            'files',
          }.every(upload.containsKey) &&
          hash(upload['sha256'], 64) &&
          between(upload['size'], 1, 99999999) &&
          between(upload['unpacked_bytes'], 0, 255999999) &&
          between(upload['files'], 1, maxArchiveEntries - 1),
      'Invalid expected pub upload archive',
    );
  }
  final identity = receiptObject(value['source']),
      archive = receiptObject(value['archive']);
  final locks = receiptObject(identity['lockfile_sha256']);
  requireReceipt(
    identity.length == 3 &&
        {'commit', 'tree', 'lockfile_sha256'}.every(identity.containsKey) &&
        locks.length == 2 &&
        {
          'pubspec.lock',
          'assets/typescript/package-lock.json',
        }.every(locks.containsKey) &&
        archive.length == 2 &&
        {'size', 'sha256'}.every(archive.containsKey) &&
        between(archive['size'], 1, maxArchiveBytes) &&
        hash(identity['commit'], 40) &&
        hash(identity['tree'], 40) &&
        hash(value['file_set_sha256'], 64) &&
        hash(archive['sha256'], 64) &&
        locks.values.every((value) => hash(value, 64)),
    'Invalid expected source/archive identity',
  );
  for (final key in ['run_id', 'run_attempt']) {
    requireReceipt(
      value[key] is String &&
          RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value[key] as String),
      'Invalid run identity',
    );
  }
  requireReceipt(
    exactReceipt(identity, source) &&
        value['run_id'] == runId &&
        value['run_attempt'] == runAttempt,
    'Transport differs from current source/run/attempt',
  );
  return value;
}
