import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_installer_receipts.dart';
import 'installed_receipt_fixtures.dart';
import 'native_installer_receipt_fixtures.dart';

void main() {
  for (final index in [2, 3, 4, 5, 7, 8, 9]) {
    test(
      'binds installed payload semantics $index with coherent original hash',
      () {
        final e = fixture('linux-x64');
        final process = e.receipt['installed']['processes'][index] as Map;
        final stream = index == 4 ? 'stderr' : 'stdout';
        final log = File(p.join(e.directory.path, process[stream] as String));
        final value = jsonDecode(log.readAsStringSync()) as Map;
        switch (index) {
          case 2:
            value['payload']['outcome'] = 'already_exists';
          case 3:
            value['payload']['projects'] = 1;
          case 4:
            value['payload']['out'] = 'unexpected.mmd';
          case 5:
            value['payload']['analysis_complete'] = false;
          case 7:
            value['payload'] = {};
          case 8:
            value['payload']['tool_errors'][0]['code'] = 'OTHER_ERROR';
          case 9:
            value['status'] = 'error';
        }
        final data = utf8.encode(jsonEncode(value));
        log.writeAsBytesSync(data);
        process['${stream}_sha256'] = InstallerEvidence.hash(data);
        expect(() => validate(e), throwsFormatException);
      },
    );
  }
  test('rejects duplicate keys in original installed JSON', () {
    final e = fixture('linux-x64');
    final process = e.receipt['installed']['processes'][3] as Map;
    final log = File(p.join(e.directory.path, process['stdout'] as String));
    final text = log.readAsStringSync().replaceFirst(
      '{',
      '{"command":"validate",',
    );
    log.writeAsStringSync(text);
    process['stdout_sha256'] = InstallerEvidence.hash(utf8.encode(text));
    expect(() => validate(e), throwsFormatException);
  });
  test(
    'rejects malformed Windows installation root before phase inspection',
    () {
      final e = fixture('windows-x64');
      e.receipt['installed']['installation_root'] = 42;
      expect(() => validate(e), throwsFormatException);
    },
  );
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    test(
      '$target accepts truthful complete installer and original suite logs',
      () {
        final e = fixture(target);
        expect(validate(e).path, e.artifact.path);
      },
    );
  }
  final mutations = <String, void Function(InstallerEvidence)>{
    'missing installer': (e) => e.proof.remove('installer'),
    'bundle digest': (e) => e.receipt['bundle_manifest_sha256'] = 'e' * 64,
    'artifact name': (e) => e.receipt['artifact']['name'] = 'test-only-old.deb',
    'artifact float size': (e) =>
        e.receipt['artifact']['size'] = e.artifact.lengthSync().toDouble(),
    'missing cases': (e) => (e.receipt['cases'] as List).removeLast(),
    'old production marker': (e) =>
        e.receipt['old_fixture']['test_only'] = false,
    'old version': (e) => e.receipt['old_fixture']['version'] = '0.1.0',
    'old stale file': (e) =>
        e.receipt['old_fixture']['removed_file'] = 'other.txt',
    'compiler relative': (e) => e.receipt['compiler']['path'] = 'dpkg-deb',
    'compiler name': (e) =>
        e.receipt['compiler']['path'] = '/usr/bin/different',
    'compiler version': (e) => e.receipt['compiler']['version'] = ' ',
    'compiler digest': (e) => e.receipt['compiler']['sha256'] = 'invalid',
    'fixture digest': (e) =>
        e.receipt['old_fixture']['manifest_sha256'] = 'invalid',
    'fixture artifact digest': (e) =>
        e.receipt['old_fixture']['artifact_sha256'] = 'invalid',
    'missing commands': (e) => e.receipt['commands'] = [],
    'failed lifecycle': (e) => e.commands[0]['exit'] = 1,
    'float lifecycle exit': (e) => e.commands[0]['exit'] = 0.0,
    'extra recorder field': (e) => e.commands[0]['accepted'] = true,
    'empty arguments': (e) => e.commands[0]['arguments'] = [],
    'non-string argument': (e) => e.commands[0]['arguments'] = [123],
    'traversing log': (e) => e.commands[0]['stdout'] = '../outside.log',
    'duplicate log': (e) => e.commands[0]['stderr'] = e.commands[0]['stdout'],
    'log digest': (e) => e.commands[0]['stdout_sha256'] = 'e' * 64,
    'installed digest': (e) =>
        e.receipt['installed']['manifest_sha256'] = 'e' * 64,
    'installed controls': (e) =>
        e.receipt['installed']['runtime_controls'] = [],
    'installed command count': (e) =>
        (e.receipt['installed']['processes'] as List).removeLast(),
    'installed exit': (e) => e.receipt['installed']['processes'][1]['exit'] = 1,
    'installed binary': (e) => e.receipt['installed']['binary'] = 'relative',
    'suite inventory': (e) => e.receipt['installed']['suites'] = [],
    'suite failure': (e) =>
        e.receipt['installed']['suites'][0]['exit_code'] = 1,
    'suite timeout': (e) =>
        e.receipt['installed']['suites'][0]['timed_out'] = true,
  };
  for (final entry in mutations.entries) {
    test('rejects ${entry.key}', () {
      final e = fixture('linux-x64');
      entry.value(e);
      expect(() => validate(e), throwsFormatException);
    });
  }
  for (var index = 0; index < 10; index++) {
    test('binds original installed stream $index even with a fresh digest', () {
      final e = fixture('linux-x64');
      final process = e.receipt['installed']['processes'][index] as Map;
      final stream = index == 4 ? 'stderr' : 'stdout';
      final data = utf8.encode(
        index < 2 ? 'forged output' : '{"command":"validate","exit_code":0}',
      );
      File(p.join(e.directory.path, process[stream] as String))
          .writeAsBytesSync(data);
      process['${stream}_sha256'] = InstallerEvidence.hash(data);
      expect(() => validate(e), throwsFormatException);
    });
  }
  for (final name in ['plan_query', 'dart_check']) {
    test('binds every installed $name Dart operand to original execution', () {
      final e = fixture('linux-x64');
      final suite =
          e.receipt['installed']['suites'][name == 'plan_query' ? 0 : 1] as Map;
      final argv = suite['command'] as List;
      for (var i = 0; i < argv.length; i++) {
        final original = argv[i];
        argv[i] = '$original-changed';
        File(p.join(e.directory.path, 'suites/$name.json'))
            .writeAsStringSync(jsonEncode(suite));
        expect(
          () => validate(e),
          throwsFormatException,
          reason: '$name operand $i',
        );
        argv[i] = original;
      }
    });
  }
  test('rejects changed original suite JSON and logs', () {
    final e = fixture('linux-x64');
    File(p.join(e.directory.path, 'suites/plan_query.json'))
        .writeAsStringSync('{}');
    expect(() => validate(e), throwsFormatException);
    final suite = e.receipt['installed']['suites'][0];
    File(p.join(e.directory.path, 'suites/plan_query.json'))
        .writeAsStringSync(jsonEncode(suite));
    File(p.join(e.directory.path, 'suites/plan_query.stdout.log'))
        .writeAsStringSync('changed');
    expect(() => validate(e), throwsFormatException);
  });
  test('rejects aliased installer and log files', () {
    final e = fixture('linux-x64');
    final moved = e.artifact.renameSync('${e.artifact.path}.original');
    Link(e.artifact.path).createSync(moved.path);
    expect(() => validate(e), throwsFormatException);
    Link(e.artifact.path).deleteSync();
    moved.renameSync(e.artifact.path);
    final log = File(
      p.join(e.directory.path, e.commands[0]['stdout'] as String),
    );
    final original = log.renameSync('${log.path}.original');
    Link(log.path).createSync(original.path);
    expect(() => validate(e), throwsFormatException);
  });

  test(
    'binds Debian installer bytes and ten original installed command outputs',
    () {
      final e = InstallerEvidence('linux-x64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      addInstalledReceipts(e);
      expect(
        validateInstaller(
          e.proof,
          e.root,
          e.manifest,
          repository: Directory.current,
          version: e.version,
        ).path,
        e.artifact.path,
      );
      e.artifact.writeAsStringSync('changed installer');
      expect(
        () => validateInstaller(
          e.proof,
          e.root,
          e.manifest,
          repository: Directory.current,
          version: e.version,
        ),
        throwsFormatException,
      );
    },
  );
}

InstallerEvidence fixture(String target) {
  final e = InstallerEvidence(target);
  addTearDown(() => e.root.deleteSync(recursive: true));
  addInstalledReceipts(e);
  return e;
}

File validate(InstallerEvidence e) => validateInstaller(
  e.proof,
  e.root,
  e.manifest,
  repository: Directory.current,
  version: e.version,
);
