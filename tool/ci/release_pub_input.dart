// Bind transported wrapper bytes to a fresh canonical stage, without publishing.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../pub/stage.dart';
import '../pub/stage_inventory.dart';
import 'pub_stage_transport.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';
import 'release_thin_transport_expectation.dart';

final class PubReleaseInput {
  PubReleaseInput(
    this.stage,
    this.transport,
    this.wrapperEntrySha256,
    this.upload,
  );
  final Directory stage;
  final Map<String, Object?> transport;
  final String wrapperEntrySha256;
  final File? upload;
}

// Materialized files are owned only during the callback.
Future<T> withPubReleaseInput<T>({
  required Directory source,
  required Map<String, Object?> identity,
  required File descriptor,
  required Directory transport,
  required String expectedTransportJson,
  required String runId,
  required String runAttempt,
  required bool registryReady,
  required Future<T> Function(PubReleaseInput) inspect,
}) async {
  final expected = expectedThinPubTransport(
    expectedTransportJson,
    identity,
    runId,
    runAttempt,
    registryReady: registryReady,
  );
  final entries = transport.listSync(followLinks: false);
  requireReceipt(
    entries.length == 2 &&
        entries.every(
          (entry) =>
              entry is File &&
              [
                'installation.tar',
                'transport.json',
              ].contains(p.basename(entry.path)),
        ),
    'Unexpected pub transport directory inventory',
  );
  requireReceipt(
    exactReceipt(
      readRecord(File(p.join(transport.path, 'transport.json'))),
      expected,
    ),
    'Pub transport record differs from independent caller',
  );
  final temporary = await Directory.systemTemp.createTemp('archway-final-pub-');
  try {
    final canonical = Directory(p.join(temporary.path, 'canonical'));
    await stagePub(
      source: source,
      descriptor: descriptor,
      output: canonical,
      expectedCommit: identity['commit'] as String,
      registryReady: registryReady,
    );
    final stageIdentity = await inspectPubStage(
      canonical,
      identity,
      registryReady: registryReady,
    );
    requireReceipt(
      stageIdentity.sha256 == expected['stage_sha256'],
      'Pub transported stage differs from canonical wrapper',
    );
    final materialized = Directory(p.join(temporary.path, 'received'));
    await readPubTransport(
      File(p.join(transport.path, 'installation.tar')),
      expected,
      source,
      materialized,
      identity['commit'] as String,
      runId,
      runAttempt,
      registryReady: registryReady,
    );
    return await inspect(
      PubReleaseInput(
        materialized,
        expected,
        stageIdentity.files.files['bin/archway.dart']!.sha256,
        registryReady
            ? File(p.join(materialized.path, 'pub-package.tar.gz'))
            : null,
      ),
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}
