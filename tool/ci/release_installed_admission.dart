// Admit the complete independent npm/pub route evidence inventory.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';
import 'release_npm_expanded_receipts.dart';
import 'release_npm_termination_receipts.dart';
import 'release_pub_receipts.dart';
import 'release_receipt_values.dart';
import 'release_transport_expectation.dart';
import 'release_npm_thin_receipts.dart';
import 'release_pub_thin_receipts.dart';
import 'release_thin_transport_expectation.dart';

void admitInstalledReceipts({
  required Directory root,
  required Map<String, Object?> source,
  required String npmSha256,
  required String runId,
  required String runAttempt,
  required String expectedTransportJson,
  required bool registryReady,
  required Directory repository,
}) {
  final transport = expectedPubTransport(
    expectedTransportJson,
    source,
    runId,
    runAttempt,
    registryReady: registryReady,
  );
  const routes = {
    'local': 'local-devDependency',
    'global': 'global-prefix',
    'cache': 'npm-exec-cache',
  };
  for (final (artifact, target, route) in _installedArtifacts(
    root,
    runId,
    runAttempt,
  )) {
    final proof = receiptObject(
      readRecord(oneReceiptFile(artifact, 'report.json')),
    );
    requireReceipt(
      (proof.containsKey('registry_ready') ? proof['registry_ready'] : false) ==
          registryReady,
      'Installed report registry intent differs',
    );
    requireReceipt(
      proof['target'] == target,
      'Installed report target differs',
    );
    if (route != null) {
      requireReceipt(
        proof['source_commit'] == source['commit'] &&
            proof['run_id'] == runId &&
            proof['run_attempt'] == runAttempt &&
            proof['route'] == routes[route] &&
            proof['tarball_sha256'] == npmSha256,
        'npm report source/run/route/tarball identity differs',
      );
      final cases = receiptList(proof['cases']);
      requireReceipt(
        exactReceipt(
          cases.map((c) => receiptObject(c)['phase']).toList(),
          route == 'cache' ? ['cached'] : ['installed', 'relocated'],
        ),
        'npm installed/relocated/cache phases missing',
      );
      for (final value in cases) {
        final receipt = receiptObject(value);
        final analysis = receiptList(receipt['analysis']);
        requireReceipt(
          exactReceipt(
                [receipt['help'], receipt['version'], receipt['init']],
                [0, 0, 0],
              ) &&
              exactReceipt(
                analysis
                    .map(
                      (c) => [
                        receiptObject(c)['case'],
                        receiptObject(c)['exit'],
                      ],
                    )
                    .toList(),
                [
                  ['clean', 0],
                  ['dependency-violation', 1],
                  ['unsupported-option', 64],
                  ['missing-owned-helper', 2],
                  ['restored-clean', 0],
                ],
              ),
          'npm route checks are incomplete or failed',
        );
        validateNpmTermination(
          receipt,
          target,
          route,
          proof['node'],
          proof['npm'],
        );
        validateNpmExpanded(receipt, target, route, artifact);
      }
    } else {
      final phases = receiptObject(proof['phases']);
      requireReceipt(
        exactReceipt(proof['source'], source) &&
            exactReceipt(proof['transport'], transport) &&
            proof['file_set_sha256'] == transport['file_set_sha256'] &&
            exactReceipt(phases.keys.toList()..sort(), [
              'installed',
              'poisoned_source_snapshot',
            ]),
        'pub report source/transport/file-set identity differs',
      );
      for (final value in phases.values) {
        final commands = receiptList(receiptObject(value)['commands']);
        requireReceipt(
          exactReceipt(
                commands.map((c) => receiptObject(c)['arguments']).toList(),
                [
                  ['--help'],
                  ['--version'],
                  ['init', '--template', 'mixed'],
                ],
              ) &&
              exactReceipt(
                commands.map((c) => receiptObject(c)['exit']).toList(),
                [0, 0, 0],
              ),
          'pub installed/snapshot checks are incomplete or failed',
        );
      }
      validatePubReceipt(proof, artifact, target, repository);
    }
  }
}

Iterable<(Directory, String, String?)> _installedArtifacts(
  Directory root,
  String runId,
  String runAttempt,
) sync* {
  const targets = ['linux-x64', 'macos-arm64', 'windows-x64'];
  final expected = <String, Map<String, (String, String?)>>{
    'npm': {
      for (final target in targets)
        for (final route in ['local', 'global', 'cache'])
          'npm-installed-$route-$target-$runId-$runAttempt': (target, route),
    },
    'pub': {
      for (final target in targets)
        'pub-installed-$target-$runId-$runAttempt': (target, null),
    },
  };
  void inventory(Directory directory, Iterable<String> names) {
    final entries = directory.listSync(followLinks: false);
    requireReceipt(
      entries.every((e) => e is Directory) &&
          exactReceipt(
            (entries.map((e) => p.basename(e.path)).toList()..sort()),
            names.toList()..sort(),
          ),
      'Missing, duplicate or wrong-run installed artifact directory',
    );
  }

  inventory(root, expected.keys);
  for (final channel in expected.entries) {
    final directory = Directory(p.join(root.path, channel.key));
    inventory(directory, channel.value.keys);
    for (final entry in channel.value.entries) {
      final (target, route) = entry.value;
      yield (Directory(p.join(directory.path, entry.key)), target, route);
    }
  }
}

// Explicit native-first admission; the old live route is never a schema fallback.
void admitThinInstalledReceipts({
  required Directory root,
  required Directory repository,
  required Map<String, Object?> source,
  required String version,
  required Map<String, Object?> descriptor,
  required String descriptorSha256,
  required String npmSha256,
  required String wrapperEntrySha256,
  required String runId,
  required String runAttempt,
  required String expectedTransportJson,
  required bool registryReady,
  required String acquisitionMode,
}) {
  final transport = expectedThinPubTransport(
    expectedTransportJson,
    source,
    runId,
    runAttempt,
    registryReady: registryReady,
  );
  for (final (artifact, target, route) in _installedArtifacts(
    root,
    runId,
    runAttempt,
  )) {
    final proof = receiptObject(
      readRecord(oneReceiptFile(artifact, 'report.json')),
    );
    if (route == null) {
      validatePubThinReceipt(
        proof,
        artifact,
        repository: repository,
        source: source,
        version: version,
        target: target,
        descriptor: descriptor,
        descriptorSha256: descriptorSha256,
        transport: transport,
        wrapperEntrySha256: wrapperEntrySha256,
        runId: runId,
        runAttempt: runAttempt,
        registryReady: registryReady,
        acquisitionMode: acquisitionMode,
      );
    } else {
      validateNpmThinReceipt(
        proof,
        artifact,
        repository: repository,
        source: source,
        target: target,
        route: route,
        descriptor: descriptor,
        descriptorSha256: descriptorSha256,
        tarballSha256: npmSha256,
        runId: runId,
        runAttempt: runAttempt,
        registryReady: registryReady,
        acquisitionMode: acquisitionMode,
      );
    }
  }
}
