import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../tool/ci/installed_command_recorder.dart';

import '../tool/ci/release_npm_thin_receipts.dart';

void main() {
  test(
    'source, private acquisition and configured budgets bind original evidence',
    () async {
      final source = <String, Object?>{'commit': 'canonical'};
      final descriptor = <String, Object?>{
        'version': '0.2.0',
        'source': source,
        'targets': {
          'linux-x64': {'sha256': 'archive', 'manifest_sha256': 'manifest'},
        },
      };
      final proof = <String, dynamic>{
        'schema_version': 1,
        'status': 'passed',
        'ci_host_verified': true,
        'target': 'linux-x64',
        'route': 'local',
        'registry_ready': false,
        'run_id': 'run',
        'run_attempt': '1',
        'source_commit': 'canonical',
        'source': source,
        'native_source': source,
        'version': '0.2.0',
        'tarball_sha256': 'tarball',
        'descriptor_sha256': 'descriptor',
        'acquisition': {
          'mode': 'ci-verified-native',
          'descriptor_sha256': 'descriptor',
          'archive_sha256': 'archive',
          'manifest_sha256': 'manifest',
          'public_cold_verified': false,
        },
      };
      void admit(
        Map<String, dynamic> value, {
        Directory? artifact,
        String route = 'local',
      }) => validateNpmThinReceipt(
        value,
        artifact ?? Directory('/no-original-evidence'),
        source: source,
        descriptor: descriptor,
        target: 'linux-x64',
        route: route,
        tarballSha256: 'tarball',
        descriptorSha256: 'descriptor',
        runId: 'run',
        runAttempt: '1',
        registryReady: false,
        acquisitionMode: 'ci-verified-native',
        repository: Directory.current,
      );
      // A coherent header progresses to the next owner, rather than failing an
      // unrelated missing-file check that could make the negatives vacuous.
      expect(
        () => admit(proof),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'boundary',
            'npm runtime/archive/evidence origin differs',
          ),
        ),
      );
      for (final change in <void Function(Map<String, dynamic>)>[
        (value) => value['acquisition']['public_cold_verified'] = true,
        (value) => value['acquisition']['mode'] = 'public-https-cold',
        (value) => value['acquisition']['archive_sha256'] = 'foreign',
        (value) => value['native_source'] = {'commit': 'foreign'},
        (value) => value['ci_host_verified'] = false,
        (value) => value['schema_version'] = 1.0,
        (value) => value['run_attempt'] = '2',
      ]) {
        final changed = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
        change(changed);
        expect(
          () => admit(changed),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'identity boundary',
              'npm source/run/candidate/acquisition identity differs',
            ),
          ),
        );
      }
      final root = Directory(
        Directory.systemTemp
            .createTempSync('npm-budget-original-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final processes = Directory(p.join(root.path, 'processes'))..createSync();
      final child = File(p.join(root.path, 'child.dart'))
        ..writeAsStringSync('void main() {}');
      final recorder = InstalledCommandRecorder(output: processes);
      await recorder.capture([Platform.resolvedExecutable, child.path]);
      final original = <String, dynamic>{
        ...proof,
        'route': 'cache',
        'node_executable': '/runtime/node',
        'npm_cli': '/runtime/npm-cli.js',
        'archive_path': '/owned/archway-architecture-cli-0.2.0.tgz',
        'process_directory': 'processes',
        'processes': recorder.commands,
        'phases': [],
      };
      expect(
        () => admit(original, artifact: root, route: 'cache'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'cache configured budget',
            'Installed original configured timeout differs',
          ),
        ),
      );
      original['route'] = 'local';
      expect(
        () => admit(original, artifact: root),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'local budget reaches phase validation',
            'npm installed/relocated/cache phase inventory differs',
          ),
        ),
      );
    },
  );
}
