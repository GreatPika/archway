import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/release_thin_transport_expectation.dart';

void main() {
  test(
    'thin transport expectation binds exact source, run and explicit intent',
    () {
      final source = {
        'commit': 'a' * 40,
        'tree': 'b' * 40,
        'lockfile_sha256': {
          'pubspec.lock': 'c' * 64,
          'assets/typescript/package-lock.json': 'd' * 64,
        },
      };
      final file = {'size': 1, 'mode': 420, 'sha256': 'e' * 64};
      final record = <String, Object?>{
        'schema_version': 1,
        'source': source,
        'registry_ready': false,
        'run_id': '123',
        'run_attempt': '2',
        'stage_sha256': 'f' * 64,
        'archive': {'size': 10240, 'sha256': '1' * 64},
        'files': {'pub-stage.json': file, 'package/bin/archway.dart': file},
      };
      Map<String, dynamic> admit(
        Map<String, Object?> input, {
        bool registry = false,
      }) => expectedThinPubTransport(
        jsonEncode(input),
        source,
        '123',
        '2',
        registryReady: registry,
      );
      expect(admit(record), record);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (r) => r['run_attempt'] = '1',
        (r) => r['source']['tree'] = '9' * 40,
        (r) => r['schema_version'] = 2,
        (r) => r['registry_ready'] = true,
        (r) => r['files']['package/bin/archway.dart']['size'] = 1.0,
        (r) => r['files']['../escape'] = {
          'size': 1,
          'mode': 420,
          'sha256': 'e' * 64,
        },
      ]) {
        final changed = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
        mutate(changed);
        expect(() => admit(changed), throwsFormatException);
      }
      expect(() => admit(record, registry: true), throwsFormatException);
      final candidate = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
      candidate['schema_version'] = 2;
      candidate['registry_ready'] = true;
      candidate['files'] = {
        for (final name in [
          'pub-stage.json',
          'report.json',
          'pub-package.tar.gz',
          for (var index = 0; index < 3; index++) ...[
            'execution/installed-$index.json',
            'execution/installed-$index.stdout.log',
            'execution/installed-$index.stderr.log',
          ],
        ])
          name: file,
      };
      candidate['upload_archive'] = {
        'sha256': '2' * 64,
        'size': 2048,
        'unpacked_bytes': 4096,
        'files': 18,
      };
      expect(admit(candidate, registry: true), candidate);
      expect(() => admit(candidate), throwsFormatException);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (r) => r['upload_archive']['size'] = 100000000,
        (r) => r['upload_archive']['files'] = 18.0,
        (r) => r['upload_archive']['sha256'] = 'invalid',
        (r) => r['files'].remove('execution/installed-2.stderr.log'),
      ]) {
        final changed =
            jsonDecode(jsonEncode(candidate)) as Map<String, dynamic>;
        mutate(changed);
        expect(() => admit(changed, registry: true), throwsFormatException);
      }
    },
  );
}
