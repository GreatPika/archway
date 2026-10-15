// Source-bound identity for the explicitly private SDK installed route.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_installed_runtime_identity.dart';
import 'release_receipt_values.dart';
import 'release_thin_transport_expectation.dart';

void validatePubThinIdentity(
  Map<String, dynamic> proof,
  Directory artifact, {
  required Map<String, Object?> source,
  required String version,
  required String target,
  required Map<String, Object?> descriptor,
  required String descriptorSha256,
  required Map<String, Object?> transport,
  required String wrapperEntrySha256,
  required String runId,
  required String runAttempt,
  required bool registryReady,
  required String acquisitionMode,
}) {
  const hosts = {
    'linux-x64': ('Linux', 'x86_64', 'linux', 'x64'),
    'macos-arm64': ('Darwin', 'arm64', 'darwin', 'arm64'),
    'windows-x64': ('Windows', 'AMD64', 'win32', 'x64'),
  };
  requireReceipt(hosts.containsKey(target), 'Unknown installed pub target');
  final host = hosts[target]!;
  final selected = receiptObject(receiptObject(descriptor['targets'])[target]);
  bool digest(Object? value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  requireReceipt(
    digest(descriptorSha256) &&
        digest(wrapperEntrySha256) &&
        digest(selected['sha256']) &&
        digest(selected['manifest_sha256']) &&
        exactReceipt(descriptor['source'], source) &&
        descriptor['version'] == version,
    'Expected pub acquisition identity differs',
  );
  final expectedTransport = expectedThinPubTransport(
    jsonEncode(transport),
    source,
    runId,
    runAttempt,
    registryReady: registryReady,
  );
  requireReceipt(
    proof['schema_version'] is int &&
        proof['schema_version'] == 1 &&
        proof['status'] == 'passed' &&
        proof['version'] == version &&
        proof['route'] == 'private-hosted-sdk-global-run' &&
        proof['target'] == target &&
        proof['registry_ready'] == registryReady &&
        proof['run_id'] == runId &&
        proof['run_attempt'] == runAttempt &&
        exactReceipt(proof['source'], source) &&
        exactReceipt(proof['transport'], expectedTransport) &&
        proof['descriptor_sha256'] == descriptorSha256 &&
        proof['native_manifest_sha256'] == selected['manifest_sha256'],
    'Installed pub source/run/transport identity differs',
  );
  requireReceipt(
    acquisitionMode == 'ci-verified-native' &&
        exactReceipt(proof['acquisition'], {
          'mode': 'ci-verified-native',
          'descriptor_sha256': descriptorSha256,
          'archive_sha256': selected['sha256'],
          'manifest_sha256': selected['manifest_sha256'],
          'public_cold_verified': false,
        }),
    'Private pub evidence cannot establish public cold acquisition',
  );
  final observed = receiptObject(proof['host']);
  requireReceipt(
    proof['ci_host'] == true &&
        proof['dart'] == '3.13.3' &&
        observed['system'] == host.$1 &&
        observed['machine'] == host.$2 &&
        ['release', 'version'].every(
          (key) =>
              observed[key] is String && (observed[key] as String).isNotEmpty,
        ) &&
        exactReceipt(proof['node'], ['v24.21.0', host.$3, host.$4]),
    'Installed pub host or pinned runtime differs',
  );
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final executable = proof['native_executable'],
      wrapper = proof['activated_wrapper'];
  requireReceipt(
    executable is String &&
        wrapper is String &&
        paths.isAbsolute(executable) &&
        paths.isAbsolute(wrapper) &&
        paths.normalize(executable) == executable &&
        paths.normalize(wrapper) == wrapper,
    'Installed pub paths must be absolute and normalized',
  );
  final payload = paths.dirname(
    paths.dirname(paths.dirname(executable as String)),
  );
  requireReceipt(
    paths.basename(executable) ==
            (target == 'windows-x64' ? 'archway.exe' : 'archway') &&
        paths.basename(paths.dirname(executable)) == target &&
        paths.basename(paths.dirname(paths.dirname(executable))) == 'bin' &&
        paths.basename(payload) == selected['sha256'] &&
        paths.basename(paths.dirname(payload)) == target &&
        paths.basename(paths.dirname(paths.dirname(payload))) == version &&
        paths.basename(wrapper as String) == 'archway-$version',
    'Installed pub wrapper or native cache selection differs',
  );
  final snapshots = receiptObject(proof['snapshots']);
  final cases = receiptList(snapshots['cases']);
  requireReceipt(
    snapshots['sdk'] == '3.13.3' &&
        snapshots['source_sha256'] == wrapperEntrySha256 &&
        digest(snapshots['snapshot_sha256']) &&
        cases.length == 3,
    'Installed SDK snapshot identity differs',
  );
  final stale = receiptObject(cases[1])['exit'],
      missing = receiptObject(cases[2])['exit'];
  requireReceipt(
    stale is int &&
        stale != 0 &&
        missing is int &&
        missing != 0 &&
        exactReceipt(cases, [
          {'case': 'poisoned-source-snapshot', 'exit': 0},
          {'case': 'stale-snapshot', 'exit': stale},
          {'case': 'missing-snapshot', 'exit': missing},
        ]),
    'Installed SDK snapshot cases differ',
  );
  final wrong = receiptObject(proof['wrong_node']);
  validateInstalledWrongNodeReceipt(wrong['wrong_node'], target, artifact);
  requireReceipt(
    exactReceipt(wrong['cases'], [
          {
            'case': 'wrong-analysis-node',
            'invocation': 'installed-route',
            'exit': 2,
            'error': 'NODE_UNAVAILABLE',
          },
        ]) &&
        exactReceipt(proof['missing_node'], [
          {
            'case': 'missing-analysis-node-check',
            'invocation': 'installed-route',
            'exit': 2,
            'error': 'NODE_UNAVAILABLE',
          },
          {
            'case': 'no-node-validate',
            'invocation': 'installed-route',
            'exit': 0,
          },
        ]),
    'Installed pub runtime cases differ',
  );
}
