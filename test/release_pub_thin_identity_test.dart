// Synthetic identity admission only; this is not installed execution evidence.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../tool/ci/release_pub_thin_identity.dart';
import 'npm_expanded_receipt_fixtures.dart';

void main() {
  for (final (target, system, machine, platform, arch) in [
    ('linux-x64', 'Linux', 'x86_64', 'linux', 'x64'),
    ('macos-arm64', 'Darwin', 'arm64', 'darwin', 'arm64'),
    ('windows-x64', 'Windows', 'AMD64', 'win32', 'x64'),
  ]) {
    test(
      '$target private identity cannot acquire public cold or registry credit',
      () {
        final artifact = Directory.systemTemp.createTempSync(
          'thin-pub-identity-',
        );
        addTearDown(() => artifact.deleteSync(recursive: true));
        final runtime = npmExpandedFixture(
          artifact,
          target,
          'global',
        )['runtime_controls'];
        final windows = target == 'windows-x64';
        final paths = p.Context(
          style: windows ? p.Style.windows : p.Style.posix,
        );
        final cache = windows ? r'C:\cache' : '/cache';
        final wrapper = windows
            ? r'C:\pub\hosted\fixture\archway-2.3.4'
            : '/pub/hosted/fixture/archway-2.3.4';
        final source = {
          'commit': 'a' * 40,
          'tree': 'b' * 40,
          'lockfile_sha256': {
            'pubspec.lock': 'c' * 64,
            'assets/typescript/package-lock.json': 'd' * 64,
          },
        };
        final native = {'sha256': 'e' * 64, 'manifest_sha256': 'f' * 64};
        final descriptor = {
          'version': '2.3.4',
          'source': source,
          'targets': {target: native},
        };
        final transport = {
          'schema_version': 1,
          'registry_ready': false,
          'source': source,
          'run_id': '123',
          'run_attempt': '2',
          'stage_sha256': '1' * 64,
          'archive': {'size': 10240, 'sha256': '2' * 64},
          'files': {
            'pub-stage.json': {'size': 1, 'mode': 420, 'sha256': '3' * 64},
          },
        };
        final proof = <String, dynamic>{
          'schema_version': 1,
          'status': 'passed',
          'version': '2.3.4',
          'route': 'private-hosted-sdk-global-run',
          'source': source,
          'target': target,
          'registry_ready': false,
          'run_id': '123',
          'run_attempt': '2',
          'ci_host': true,
          'host': {
            'system': system,
            'machine': machine,
            'release': 'synthetic',
            'version': 'synthetic',
          },
          'node': ['v24.21.0', platform, arch],
          'dart': '3.13.3',
          'transport': transport,
          'descriptor_sha256': '4' * 64,
          'native_manifest_sha256': 'f' * 64,
          'native_executable': paths.join(
            cache,
            '2.3.4',
            target,
            'e' * 64,
            'bin',
            target,
            windows ? 'archway.exe' : 'archway',
          ),
          'activated_wrapper': wrapper,
          'acquisition': {
            'mode': 'ci-verified-native',
            'descriptor_sha256': '4' * 64,
            'archive_sha256': 'e' * 64,
            'manifest_sha256': 'f' * 64,
            'public_cold_verified': false,
          },
          'snapshots': {
            'sdk': '3.13.3',
            'snapshot_sha256': '5' * 64,
            'source_sha256': '6' * 64,
            'cases': [
              {'case': 'poisoned-source-snapshot', 'exit': 0},
              {'case': 'stale-snapshot', 'exit': 65},
              {'case': 'missing-snapshot', 'exit': 65},
            ],
          },
          'wrong_node': {
            'wrong_node': runtime['wrong_node'],
            'cases': [
              {
                'case': 'wrong-analysis-node',
                'invocation': 'installed-route',
                'exit': 2,
                'error': 'NODE_UNAVAILABLE',
              },
            ],
          },
          'missing_node': [
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
          ],
        };
        void admit(Map<String, dynamic> value) => validatePubThinIdentity(
          value,
          artifact,
          source: source,
          version: '2.3.4',
          target: target,
          descriptor: descriptor,
          descriptorSha256: '4' * 64,
          transport: transport,
          wrapperEntrySha256: '6' * 64,
          runId: '123',
          runAttempt: '2',
          registryReady: false,
          acquisitionMode: 'ci-verified-native',
        );
        admit(proof);
        for (final mutate in <void Function(Map<String, dynamic>)>[
          (v) => v['source']['tree'] = '9' * 40,
          (v) => v['run_attempt'] = '1',
          (v) => v['registry_ready'] = true,
          (v) => v['acquisition']['mode'] = 'public-https-cold',
          (v) => v['acquisition']['public_cold_verified'] = true,
          (v) => v['acquisition']['archive_sha256'] = '0' * 64,
          (v) => v['snapshots']['source_sha256'] = '0' * 64,
          (v) => v['snapshots']['cases'][1]['exit'] = 0,
          (v) => v['missing_node'][0]['invocation'] =
              'installed-native-supplement',
          (v) => v['wrong_node']['wrong_node']['executable_sha256'] = '0' * 64,
          (v) => v['native_executable'] = '/cache/other/bin/linux-x64/archway',
          (v) => v['ci_host'] = false,
        ]) {
          final changed = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
          mutate(changed);
          expect(() => admit(changed), throwsFormatException);
        }
      },
    );
  }
}
