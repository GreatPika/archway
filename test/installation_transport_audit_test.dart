// Transport CLI fixtures; these do not establish native acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const targets = {
  'linux-x64': ['Linux', 'x86_64'],
  'macos-arm64': ['Darwin', 'arm64'],
  'windows-x64': ['Windows', 'AMD64'],
};
const suites = [
  'native_asset_process_smoke.dart',
  'cli_process_smoke.dart',
  'dart_check_process_smoke.dart',
  'alias_trace_gap_process_smoke.dart',
];

void main() {
  final auditor = p.absolute('tool/ci/audit_installation_transports.dart');
  late Directory root;
  late String commit;
  late List<String> directories;
  late List<String> originals;
  Future<String> git(List<String> args) async {
    final result = await Process.run('git', ['-C', root.path, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  File record(int index) => File(p.join(directories[index], 'provenance.json'));
  void mutate(void Function(Map<String, dynamic>) change, {int index = 2}) {
    final data = jsonDecode(originals[index]) as Map<String, dynamic>;
    change(data);
    record(index).writeAsStringSync(jsonEncode(data));
  }

  Future<ProcessResult> invoke({List<String>? inputs, String? expected}) =>
      Process.run(Platform.resolvedExecutable, [
        auditor,
        '--expected-commit',
        expected ?? commit,
        '--report',
        p.join(root.path, 'report.json'),
        ...inputs ?? directories,
      ], workingDirectory: root.path);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('transport café-');
    await git(['init', '-q', '--template=']);
    const locks = ['pubspec.lock', 'assets/typescript/package-lock.json'];
    for (final name in locks) {
      File(p.join(root.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('lock\n');
    }
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      '-c',
      'commit.gpgSign=false',
      'commit',
      '-qm',
      'Fixture',
    ]);
    commit = await git(['rev-parse', 'HEAD']);
    final source = {
      'commit': commit,
      'tree': await git(['rev-parse', 'HEAD^{tree}']),
      'lockfile_sha256': {
        for (final name in locks)
          name: sha256.convert(utf8.encode('lock\n')).toString(),
      },
    };
    directories = [];
    originals = [];
    for (final entry in targets.entries) {
      final directory = Directory(p.join(root.path, entry.key))..createSync();
      directories.add(directory.path);
      final bytes = utf8.encode('opaque ${entry.key}');
      File(p.join(directory.path, 'installation.tar')).writeAsBytesSync(bytes);
      final windows = entry.key == 'windows-x64';
      final data = {
        'schema_version': 1,
        'source': source,
        'target': entry.key,
        'host': {
          'system': entry.value[0],
          'machine': entry.value[1],
          'release': 'fixture',
        },
        'checks': {
          'profile': windows ? 'init-only' : 'process',
          'suites': windows ? <String>[] : suites,
          'relocated_init': true,
          'transported_init': true,
        },
        'files': {
          'assets/typescript/helper.cjs': {
            'size': 1,
            'sha256': 'a' * 64,
            'mode': windows ? 438 : 420,
          },
        },
        'archive': {
          'name': 'installation.tar',
          'sha256': sha256.convert(bytes).toString(),
        },
      };
      originals.add(jsonEncode(data));
      record(directories.length - 1).writeAsStringSync(originals.last);
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'opaque transports preserve source and permit Windows mode differences',
    () async {
      final result = await invoke();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final report = jsonDecode(
        File(p.join(root.path, 'report.json')).readAsStringSync(),
      ) as Map;
      expect((report['targets'] as Map).keys, unorderedEquals(targets.keys));
      expect(report['source']['commit'], commit);
      expect(
        report['scope'],
        'transport-only; no extraction or package certification',
      );
    },
  );

  test('workflow commit must match checkout', () async {
    final result = await invoke(expected: '0' * 40);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Checkout differs'));
  });
  test('source commit tree and locks must all match', () async {
    for (final field in ['commit', 'tree', 'lockfile_sha256']) {
      mutate((r) => r['source'][field] = 'wrong');
      final result = await invoke();
      expect(result.exitCode, isNot(0), reason: field);
      expect(result.stderr, contains('source'));
    }
  });
  test('missing and duplicate targets refuse', () async {
    for (final inputs in [
      directories.take(2).toList(),
      [...directories, directories.first],
      List.filled(3, directories.first),
    ]) {
      expect((await invoke(inputs: inputs)).exitCode, isNot(0));
    }
  });
  test('archive bytes remain bound to provenance', () async {
    File(p.join(directories[1], 'installation.tar'))
        .writeAsStringSync('damaged');
    final result = await invoke();
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Archive identity mismatch'));
  });
  test(
    'shared assets must have identical size and digest and be present',
    () async {
      for (final field in ['sha256', 'size', 'missing']) {
        mutate((r) {
          if (field == 'missing') {
            r['files'].clear();
          } else {
            r['files']['assets/typescript/helper.cjs'][field] = field == 'size'
                ? 2
                : 'b' * 64;
          }
        });
        expect((await invoke()).exitCode, isNot(0), reason: field);
      }
    },
  );
  test('schema host and exact completed check claims are required', () async {
    final changes = <void Function(Map<String, dynamic>)>[
      (r) => r['schema_version'] = 2,
      (r) => r['host']['system'] = 'Linux',
      (r) => r['checks']['transported_init'] = 1,
      (r) => r['checks']['relocated_init'] = false,
      (r) => r['checks']['profile'] = 'process',
      (r) => r['checks']['suites'] = ['invented'],
    ];
    for (final change in changes) {
      mutate(change);
      expect((await invoke()).exitCode, isNot(0));
    }
    // Old-runtime receipt identities cannot stand in for the routed Dart suites.
    record(2).writeAsStringSync(originals[2]);
    mutate(
      (r) => r['checks']['suites'] = suites
          .map((name) => name.replaceAll('.dart', '.py'))
          .toList(),
      index: 0,
    );
    final result = await invoke();
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('required check profile mismatch'));
  });
  test('invalid inventory refuses even when every target agrees', () async {
    for (final entry in [
      {'size': -1, 'sha256': 'a' * 64, 'mode': 420},
      {'size': true, 'sha256': 'a' * 64, 'mode': 420},
      {'size': 1, 'sha256': 'not-a-hash', 'mode': 420},
    ]) {
      for (var index = 0; index < directories.length; index++) {
        mutate(
          (r) => r['files'] = {'assets/typescript/helper.cjs': entry},
          index: index,
        );
      }
      final result = await invoke();
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Invalid file inventory'));
    }
  });
}
