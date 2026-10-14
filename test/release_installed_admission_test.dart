import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_installed_admission.dart';
import '../tool/ci/release_transport_expectation.dart';
import 'installed_route_receipt_fixtures.dart';

void main() {
  for (final ready in [false, true]) {
    test('admit all twelve routes with exact registry intent $ready', () {
      final root = Directory.systemTemp.createTempSync('installed-receipts-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = <String, Object?>{
        'commit': 'a' * 40,
        'tree': 'b' * 40,
        'lockfile_sha256': {
          'pubspec.lock': 'c' * 64,
          'assets/typescript/package-lock.json': 'd' * 64,
        },
      };
      final transport = installedRouteFixture(
        root,
        source,
        '2' * 64,
        registryReady: ready,
      );
      void validate([Map<String, dynamic>? expected]) => admitInstalledReceipts(
        root: root,
        source: source,
        npmSha256: '2' * 64,
        runId: '123',
        runAttempt: '1',
        expectedTransportJson: jsonEncode(expected ?? transport),
        registryReady: ready,
        repository: Directory.current,
      );
      validate();
      final npm = File(
        p.join(
          root.path,
          'npm/npm-installed-cache-windows-x64-123-1/report.json',
        ),
      );
      final pub = File(
        p.join(
          root.path,
          'pub/pub-installed-windows-x64-123-1/nested/report.json',
        ),
      );
      for (final file in [npm, pub]) {
        final original = file.readAsStringSync();
        for (final intent in [!ready, 1, null]) {
          final changed = jsonDecode(original) as Map;
          changed['registry_ready'] = intent;
          file.writeAsStringSync(jsonEncode(changed));
          expect(validate, throwsFormatException);
        }
        file.writeAsStringSync(original);
      }
      final original = pub.readAsStringSync();
      final changed = jsonDecode(original) as Map;
      if (ready) {
        changed['transport']['upload_archive']['sha256'] = '3' * 64;
      } else {
        changed['transport']['archive']['sha256'] = '3' * 64;
      }
      pub.writeAsStringSync(jsonEncode(changed));
      expect(validate, throwsFormatException);
      pub.writeAsStringSync(original);
      final wrong = jsonDecode(jsonEncode(transport)) as Map<String, dynamic>;
      wrong['run_attempt'] = '2';
      expect(() => validate(wrong), throwsFormatException);
      final data = npm.readAsStringSync();
      npm.deleteSync();
      expect(validate, throwsFormatException);
      npm.writeAsStringSync(data);

      for (final mutate in <void Function(Map)>[
        (p) => p['cases'][0]['phase'] = 'wrong-phase',
        (p) => p['cases'][0]['help'] = true,
        (p) => p['cases'][0]['analysis'][0]['exit'] = 0.0,
      ]) {
        final changed = jsonDecode(data) as Map;
        mutate(changed);
        npm.writeAsStringSync(jsonEncode(changed));
        expect(validate, throwsFormatException);
      }
      npm.writeAsStringSync(data);
      for (final mutate in <void Function(Map)>[
        (t) => t['schema_version'] = (t['schema_version'] as int).toDouble(),
        (t) => t['archive']['size'] = 0,
        (t) => t['archive']['sha256'] = 'invalid',
        (t) => t['run_id'] = '0',
        (t) => t['run_attempt'] = '01',
        (t) => t['extra'] = true,
        if (ready) (t) => t['upload_archive']['size'] = 100000000,
      ]) {
        final changed =
            jsonDecode(jsonEncode(transport)) as Map<String, dynamic>;
        mutate(changed);
        expect(
          () => expectedPubTransport(
            jsonEncode(changed),
            source,
            changed['run_id'] as String,
            changed['run_attempt'] as String,
            registryReady: ready,
          ),
          throwsFormatException,
        );
      }
      final route = npm.parent;
      final moved = route.renameSync(route.path + '-wrong-run');
      expect(validate, throwsFormatException);
      moved.renameSync(route.path);
      final extra = Directory(p.join(root.path, 'extra-channel'))..createSync();
      expect(validate, throwsFormatException);
      extra.deleteSync();
      final duplicate = Directory(p.join(route.path, 'duplicate'))
        ..createSync();
      npm.copySync(p.join(duplicate.path, 'report.json'));
      expect(validate, throwsFormatException);
      duplicate.deleteSync(recursive: true);
      validate();
    });
  }
}
