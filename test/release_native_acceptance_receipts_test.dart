import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_native_acceptance_receipts.dart';
import 'native_acceptance_receipt_fixtures.dart';

void main() {
  for (final target in flutterPins.keys) {
    test('accepts independently recorded complete $target evidence', () {
      final evidence = Evidence(target);
      addTearDown(() => evidence.root.deleteSync(recursive: true));
      validateNative(
        evidence.proof,
        evidence.report,
        evidence.root,
        evidence.source,
      );
    });
  }
  test('rejects drive-root-relative Windows fixture paths', () {
    final evidence = Evidence('windows-x64');
    addTearDown(() => evidence.root.deleteSync(recursive: true));
    evidence.fixture['pub_fixture'] = r'\relative-root\pub';
    evidence.saveFixture();
    // Keep receipt operands coherent so rejection must come from path validation.
    ((evidence.acceptance['suites'] as List)[16]['command'] as List)[6] =
        r'\relative-root\pub';
    final suite = (evidence.acceptance['suites'] as List)[16];
    File(p.join(evidence.directory.path, 'package_provenance.json'))
        .writeAsStringSync(jsonEncode(suite));
    expect(
      () => validateNative(
        evidence.proof,
        evidence.report,
        evidence.root,
        evidence.source,
      ),
      throwsFormatException,
    );
  });
  final corruptions = <String, void Function(Evidence)>{
    'source-only budget on native suite': (e) {
      final receipt = (e.acceptance['suites'] as List).first as Map;
      receipt['timeout_seconds'] = 900;
      File(p.join(e.directory.path, '${receipt['suite']}.json'))
          .writeAsStringSync(jsonEncode(receipt));
    },
    'unknown target': (e) => e.proof['target'] = 'linux-arm64',
    'unremoved original': (e) =>
        (e.proof['relocation'] as Map)['original_removed'] = false,
    'same relocation': (e) => (e.proof['relocation'] as Map)['extracted'] =
        (e.proof['relocation'] as Map)['executed'],
    'relative relocation': (e) =>
        (e.proof['relocation'] as Map)['executed'] = 'relative',
    'old Python format': (e) => e.acceptance['python'] = '/python',
    'missing field': (e) => e.acceptance.remove('scope'),
    'wrong scope': (e) => e.acceptance['scope'] = 'partial',
    'source mismatch': (e) => e.acceptance['source'] = {},
    'archive source mismatch': (e) => e.proof['source'] = {},
    'source root mismatch': (e) =>
        e.proof['source_root'] = e.acceptance['output_root'],
    'relative Node': (e) => e.acceptance['node_path'] = 'node',
    'relative output': (e) => e.acceptance['output_root'] = 'output',
    'runtime version': (e) => (e.proof['node'] as List)[0] = 'v24.19.0',
    'runtime platform': (e) => (e.proof['node'] as List)[1] = 'wrong',
    'runtime architecture': (e) => (e.proof['node'] as List)[2] = 'wrong',
    'fixture source': (e) => e.fixture['source'] = {},
    'fixture target': (e) => e.fixture['target'] = 'other',
    'floating schema': (e) => e.fixture['schema_version'] = 1.0,
    'missing readiness project': (e) =>
        (e.fixture['readiness'] as Map).remove('pub/hosted'),
    'missing readiness file': (e) =>
        ((e.fixture['readiness'] as Map)['git-fixture'] as Map).remove(
          'pubspec.lock',
        ),
    'extra readiness file': (e) =>
        ((e.fixture['readiness'] as Map)['flutter-fixture'] as Map)['extra'] =
            'a' * 64,
    'malformed readiness hash': (e) =>
        ((e.fixture['readiness'] as Map)['pub/path'] as Map)['pubspec.yaml'] =
            'A' * 64,
    'unbound Git environment': (e) =>
        (e.fixture['environment'] as Map)['ARCHWAY_PUB_GIT_FIXTURE'] =
            e.fixture['pub_fixture'],
    'missing Flutter environment': (e) =>
        (e.fixture['environment'] as Map).remove('ARCHWAY_FLUTTER_FIXTURE'),
    'missing suite': (e) => (e.acceptance['suites'] as List).removeLast(),
    'duplicate suite': (e) => (e.acceptance['suites'] as List)[1] =
        (e.acceptance['suites'] as List)[0],
    'reordered suites': (e) {
      final suites = e.acceptance['suites'] as List;
      final first = suites[0];
      suites[0] = suites[1];
      suites[1] = first;
    },
  };
  for (final target in flutterPins.keys) {
    for (final corruption in corruptions.entries) {
      test('$target rejects ${corruption.key}', () {
        final e = Evidence(target);
        addTearDown(() => e.root.deleteSync(recursive: true));
        corruption.value(e);
        e.saveFixture();
        expect(
          () => validateNative(e.proof, e.report, e.root, e.source),
          throwsFormatException,
        );
      });
    }
    for (final pin in [
      'dart',
      'collection',
      'git.url',
      'git.ref',
      'flutter.archive',
      'flutter.version',
      'flutter.sha256',
      'wrong_node.version',
      'wrong_node.sha256',
    ]) {
      test('$target rejects changed pin $pin', () {
        final e = Evidence(target);
        addTearDown(() => e.root.deleteSync(recursive: true));
        final parts = pin.split('.');
        final pins = e.fixture['pins'] as Map;
        (parts.length == 1 ? pins : pins[parts.first] as Map)[parts.last] =
            'changed';
        e.saveFixture();
        expect(
          () => validateNative(e.proof, e.report, e.root, e.source),
          throwsFormatException,
        );
      });
    }
    for (var i = 0; i < names.length; i++) {
      test('$target independently binds every ${names[i]} operand', () {
        final e = Evidence(target);
        addTearDown(() => e.root.deleteSync(recursive: true));
        final receipt = (e.acceptance['suites'] as List)[i] as Map;
        final command = receipt['command'] as List;
        for (var argument = 0; argument < command.length; argument++) {
          final original = command[argument];
          command[argument] = '$original-changed';
          File(p.join(e.directory.path, '${names[i]}.json'))
              .writeAsStringSync(jsonEncode(receipt));
          expect(
            () => validateNative(e.proof, e.report, e.root, e.source),
            throwsFormatException,
            reason: '${names[i]} argv[$argument]',
          );
          command[argument] = original;
        }
      });
    }
  }
  for (final bad in <String, Object?>{
    'exit_code': 1,
    'timed_out': true,
    'timeout_seconds': 599,
    'elapsed_seconds': -1,
    'stdout': '../outside.log',
    'stderr_sha256': 'not-a-digest',
    'suite': 'other',
  }.entries) {
    test('rejects failed or unsafe native proof ${bad.key}', () {
      final e = Evidence('linux-x64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      final receipt = (e.acceptance['suites'] as List).first as Map;
      receipt[bad.key] = bad.value;
      File(p.join(e.directory.path, 'plan_query.json'))
          .writeAsStringSync(jsonEncode(receipt));
      expect(
        () => validateNative(e.proof, e.report, e.root, e.source),
        throwsFormatException,
      );
    });
  }
  test('rejects an aliased original fixture manifest', () {
    final e = Evidence('linux-x64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    final file = File(p.join(e.root.path, 'acceptance-fixtures.json'));
    final moved = file.renameSync(p.join(e.root.path, 'fixture-original.json'));
    Link(file.path).createSync(moved.path);
    expect(
      () => validateNative(e.proof, e.report, e.root, e.source),
      throwsFormatException,
    );
  });
  for (final corruption in [
    'fixture hash',
    'fixture JSON',
    'duplicate fixture',
    'receipt JSON',
    'stdout bytes',
    'stderr bytes',
  ]) {
    test('binds original $corruption', () {
      final e = Evidence('linux-x64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      final fixtureFile = File(p.join(e.root.path, 'acceptance-fixtures.json'));
      switch (corruption) {
        case 'fixture hash':
          (e.acceptance['fixtures'] as Map)['sha256'] = 'f' * 64;
        case 'fixture JSON':
          fixtureFile.writeAsStringSync('{"target":0,"target":1}');
          (e.acceptance['fixtures'] as Map)['sha256'] = sha256
              .convert(fixtureFile.readAsBytesSync())
              .toString();
        case 'duplicate fixture':
          fixtureFile.copySync(
            p.join(e.directory.path, 'acceptance-fixtures.json'),
          );
        case 'receipt JSON':
          File(p.join(e.directory.path, 'plan_query.json'))
              .writeAsStringSync('{}');
        case 'stdout bytes':
          File(p.join(e.directory.path, 'plan_query.stdout.log'))
              .writeAsStringSync('changed');
        case 'stderr bytes':
          File(p.join(e.directory.path, 'plan_query.stderr.log'))
              .writeAsStringSync('changed');
      }
      expect(
        () => validateNative(e.proof, e.report, e.root, e.source),
        throwsFormatException,
      );
    });
  }
  for (final recorded in ['/evidence/source/../source', '//evidence/source']) {
    test('preserves lexical source-root identity: $recorded', () {
      final e = Evidence('linux-x64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      e.proof['source_root'] = recorded;
      expect(
        () => validateNative(e.proof, e.report, e.root, e.source),
        throwsFormatException,
      );
    });
  }
  test('requires mandatory prepared fixture readiness', () {
    final evidence = Evidence('linux-x64');
    addTearDown(() => evidence.root.deleteSync(recursive: true));
    evidence.fixture.remove('readiness');
    evidence.saveFixture();
    expect(
      () => validateNative(
        evidence.proof,
        evidence.report,
        evidence.root,
        evidence.source,
      ),
      throwsFormatException,
    );
  });
}
