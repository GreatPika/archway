import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_source_receipts.dart';

String digest(List<int> bytes) => sha256.convert(bytes).toString();

class Fixture {
  final Directory root = Directory.systemTemp.createTempSync('source-receipt-');
  late final Directory repo = Directory(p.join(root.path, 'repo'))
    ..createSync();
  late final Directory evidence = Directory(p.join(root.path, 'acceptance'))
    ..createSync();
  late final File report = File(p.join(root.path, 'report.json'));
  late Map<String, dynamic> proof, source, manifest;
  late List<Map<String, dynamic>> events;

  Fixture(String target, {String testPath = 'test/example_test.dart'}) {
    final windows = target == 'windows-x64';
    final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    final sdk = windows ? r'C:\fixtures\dart-sdk' : '/fixtures/dart-sdk';
    final dart = paths.join(sdk, 'bin', windows ? 'dart.exe' : 'dart');
    final identity = {'commit': 'a' * 40, 'dirty': false};
    writeTracked('pubspec.lock', 'locked\n');
    writeTracked(testPath, 'test source\n');
    git(['init', '--quiet']);
    git(['add', '.']);
    final snapshot = {
      for (final name in ['pubspec.lock', testPath])
        name: digest(File(p.join(repo.path, name)).readAsBytesSync()),
    };
    final snapshotFile = File(p.join(evidence.path, 'source-files.json'))
      ..writeAsStringSync(jsonEncode(snapshot));
    final assets = {
      'assets/typescript/vendor/typescript.js': digest(utf8.encode('vendor')),
      'native/$target/library': digest(utf8.encode('native')),
    };
    events = [
      {
        'type': 'suite',
        'suite': {'id': 0, 'path': testPath},
      },
      {
        'type': 'testStart',
        'test': {'id': 1, 'suiteID': 0, 'name': 'works'},
      },
      {
        'type': 'testDone',
        'testID': 1,
        'result': 'success',
        'hidden': false,
        'skipped': false,
      },
      {'type': 'done', 'success': true},
    ];
    source = {
      'source': identity,
      'target': target,
      'snapshot_root': windows ? r'C:\temporary\source' : '/temporary/source',
      'dart': dart,
      'snapshot_manifest': 'source-files.json',
      'snapshot_manifest_sha256': digest(snapshotFile.readAsBytesSync()),
      'assets': assets,
      'preparation': execution('source-pub-get', [
        dart,
        '--suppress-analytics',
        'pub',
        'get',
        '--enforce-lockfile',
      ], ''),
      'execution': execution(
        'source-tests',
        [dart, 'test', '--reporter=json'],
        eventLog(),
        timeout: 900,
      ),
      'tests': {
        'suites': [testPath],
        'passed': 1,
        'skipped': [],
      },
    };
    final readiness = {
      for (final name in [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
      ])
        name: 'b' * 64,
    };
    proof = {
      'source': identity,
      'target': target,
      'source_root': windows ? r'C:\checkout' : '/checkout',
      'acceptance': {
        'source_suite': source,
        'fixtures': {
          'manifest': {
            'dart_sdk': sdk,
            'git_fixture': 'git-fixture',
            'flutter_fixture': 'flutter-fixture',
            'environment': {
              'ARCHWAY_PUB_GIT_FIXTURE': 'git-fixture',
              'ARCHWAY_FLUTTER_FIXTURE': 'flutter-fixture',
            },
            'readiness': {
              'git-fixture': {...readiness},
              'flutter-fixture': {...readiness},
            },
          },
        },
      },
    };
    manifest = {
      'source': identity,
      'target': target,
      'files': {
        for (final entry in assets.entries) entry.key: {'sha256': entry.value},
        'bin/archway': {'sha256': 'c' * 64},
      },
    };
  }

  void writeTracked(String name, String contents) {
    final file = File(p.join(repo.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  void git(List<String> arguments) {
    final result = Process.runSync('git', ['-C', repo.path, ...arguments]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  }

  String eventLog() => '${events.map(jsonEncode).join('\n')}\n';

  Map<String, dynamic> execution(
    String suite,
    List<String> command,
    String stdout, {
    int timeout = 600,
  }) {
    final receipt = <String, dynamic>{
      'suite': suite,
      'command': command,
      'exit_code': 0,
      'timed_out': false,
      'elapsed_seconds': 0.25,
      'timeout_seconds': timeout,
    };
    for (final stream in ['stdout', 'stderr']) {
      final bytes = utf8.encode(stream == 'stdout' ? stdout : '');
      final name = '$suite.$stream.log';
      File(p.join(evidence.path, name)).writeAsBytesSync(bytes);
      receipt[stream] = name;
      receipt['${stream}_sha256'] = digest(bytes);
    }
    File(p.join(evidence.path, '$suite.json'))
        .writeAsStringSync(jsonEncode(receipt));
    return receipt;
  }

  void replaceEvents(String text) {
    source['execution'] = execution(
      'source-tests',
      List<String>.from(source['execution']['command']),
      text,
      timeout: 900,
    );
  }

  void rewriteSnapshot(String text) {
    final file = File(p.join(evidence.path, 'source-files.json'))
      ..writeAsStringSync(text);
    source['snapshot_manifest_sha256'] = digest(file.readAsBytesSync());
  }

  Future<void> validate() => validateSource(proof, report, manifest, repo);
  void close() => root.deleteSync(recursive: true);
}

void main() {
  for (final recorded in [
    '/fixtures/dart-sdk/child/../bin/dart',
    '//fixtures/dart-sdk/bin/dart',
  ]) {
    test(
      'rejects lexically distinct SDK $recorded without changing commands',
      () async {
        final f = Fixture('linux-x64');
        addTearDown(f.close);
        f.source['dart'] = recorded;
        await expectLater(f.validate(), throwsA(isA<FormatException>()));
      },
    );
  }
  for (final recorded in ['/fixtures/child/../git', '//fixtures/git']) {
    test('rejects lexically distinct fixture environment $recorded', () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      final manifest = f.proof['acceptance']['fixtures']['manifest'];
      manifest['git_fixture'] = '/fixtures/git';
      manifest['environment']['ARCHWAY_PUB_GIT_FIXTURE'] = recorded;
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    });
  }
  for (final recorded in ['/checkout/child/..', '//checkout']) {
    test('snapshot path retains lexical identity $recorded', () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      f.source['snapshot_root'] = recorded;
      await f.validate();
    });
  }
  test(
    'same original snapshot with harmless dot spelling is rejected',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      f.source['snapshot_root'] = '/checkout/./';
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );
  test(
    'original receipt mismatch rejects otherwise valid embedded execution',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      f.source['execution']['elapsed_seconds'] = 0.5;
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );

  test(
    'recomputes an existing explicit platform skip from original events',
    () async {
      const path = 'test/flutter_sdk_copy_test.dart';
      const name =
          'Windows deep source and destination remain real isolated hardlinks';
      const reason = 'Requires native Windows hardlinks.';
      final f = Fixture('linux-x64', testPath: path);
      addTearDown(f.close);
      f.events[1]['test']['name'] = name;
      f.events[1]['test']['metadata'] = {'skipReason': reason};
      f.events[2]['skipped'] = true;
      f.source['tests'] = {
        'suites': [path],
        'passed': 0,
        'skipped': [
          {
            'file': path,
            'name': name,
            'reason': reason,
            'applicability':
                'Existing explicit source-fixture OS/filesystem guard',
          },
        ],
      };
      f.replaceEvents(f.eventLog());
      await f.validate();
      f.events[1]['test']['metadata']['skipReason'] =
          'Host lacks required capability';
      f.source['tests']['skipped'][0]['reason'] =
          'Host lacks required capability';
      f.replaceEvents(f.eventLog());
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );
  test('accepts fully qualified UNC snapshot recorded on Windows', () async {
    final f = Fixture('windows-x64');
    addTearDown(f.close);
    f.source['snapshot_root'] = r'\\server\share\snapshot';
    await f.validate();
  });
  test('does not treat POSIX path spelling as case insensitive', () async {
    final f = Fixture('linux-x64');
    addTearDown(f.close);
    f.source['dart'] = '/FIXTURES/dart-sdk/bin/dart';
    await expectLater(f.validate(), throwsA(isA<FormatException>()));
  });
  test(
    'rejects original snapshot JSON above the shared evidence bound',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      final snapshot = File(p.join(f.evidence.path, 'source-files.json'))
          .readAsStringSync();
      f.rewriteSnapshot('$snapshot${' ' * (2 * 1024 * 1024)}');
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );
  test(
    'rejects original source log bytes even if summary remains plausible',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      File(p.join(f.evidence.path, 'source-tests.stdout.log'))
          .writeAsStringSync('${f.eventLog()} ');
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );
  test('rejects missing original preparation receipt', () async {
    final f = Fixture('linux-x64');
    addTearDown(f.close);
    File(p.join(f.evidence.path, 'source-pub-get.json')).deleteSync();
    await expectLater(f.validate(), throwsA(isA<FormatException>()));
  });

  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    test(
      'validates $target recorded paths independently of this host',
      () async {
        final f = Fixture(target);
        addTearDown(f.close);
        if (target == 'windows-x64') {
          f.source['dart'] = r'c:/FIXTURES/dart-sdk/bin/dart.exe';
          f.events[0]['suite']['path'] = r'test\example_test.dart';
          f.replaceEvents(f.eventLog());
        }
        await f.validate();
      },
    );
  }
  final mutations = <String, void Function(Fixture)>{
    'source identity': (f) => f.source['source'] = {'commit': 'wrong'},
    'archive identity': (f) => f.manifest['source'] = {'commit': 'wrong'},
    'source target': (f) => f.source['target'] = 'windows-x64',
    'archive target': (f) => f.manifest['target'] = 'windows-x64',
    'unsupported target': (f) => f.proof['target'] = 'unknown',
    'relative snapshot': (f) => f.source['snapshot_root'] = 'temporary/source',
    'original checkout snapshot': (f) =>
        f.source['snapshot_root'] = '/checkout',
    'wrong SDK': (f) => f.source['dart'] = '/another/bin/dart',
    'wrong snapshot filename': (f) =>
        f.source['snapshot_manifest'] = '../source-files.json',
    'snapshot hash': (f) => f.source['snapshot_manifest_sha256'] = '0' * 64,
    'tracked bytes': (f) => f.writeTracked('pubspec.lock', 'changed'),
    'tracked inventory': (f) {
      f.writeTracked('new.txt', 'new');
      f.git(['add', '.']);
    },
    'missing snapshot entry': (f) => f.rewriteSnapshot('{}'),
    'duplicate snapshot key': (f) {
      final snapshot = File(p.join(f.evidence.path, 'source-files.json'))
          .readAsStringSync();
      final inventory = jsonDecode(snapshot) as Map<String, dynamic>;
      final key = inventory.keys.first;
      f.rewriteSnapshot(
        '{${jsonEncode(key)}:${jsonEncode(inventory[key])},${snapshot.substring(1)}',
      );
    },
    'asset digest': (f) =>
        f.source['assets']['native/linux-x64/library'] = '0' * 64,
    'extra archive asset': (f) =>
        f.manifest['files']['native/linux-x64/other'] = {'sha256': 'a' * 64},
    'empty archive assets': (f) {
      f.manifest['files'] = <String, dynamic>{};
      f.source['assets'] = <String, dynamic>{};
    },
    'preparation argv': (f) =>
        f.source['preparation']['command'][4] = '--offline',
    'execution argv': (f) =>
        f.source['execution']['command'][2] = '--reporter=compact',
    'execution inventory': (f) =>
        f.source['execution']['suite'] = 'source-pub-get',
    'preparation inventory': (f) =>
        f.source['preparation']['suite'] = 'source-tests',
    'preparation exit': (f) => f.source['preparation']['exit_code'] = 1,
    'execution exit': (f) => f.source['execution']['exit_code'] = 1,
    'preparation timeout': (f) => f.source['preparation']['timed_out'] = true,
    'preparation source-only timeout budget': (f) =>
        f.source['preparation']['timeout_seconds'] = 900,
    'execution obsolete process-suite timeout budget': (f) =>
        f.source['execution']['timeout_seconds'] = 600,
    'execution fractional timeout budget': (f) =>
        f.source['execution']['timeout_seconds'] = 900.0,
    'summary pass count': (f) => f.source['tests']['passed'] = 2,
    'summary inventory': (f) => f.source['tests']['suites'] = [],
    'summary unknown field': (f) => f.source['tests']['extra'] = true,
    'event duplicate JSON key': (f) =>
        f.replaceEvents('{"type":"done","type":"done","success":true}\n'),
    'event blank line': (f) => f.replaceEvents('\n${f.eventLog()}'),
    'event missing terminal': (f) {
      f.events.removeLast();
      f.replaceEvents(f.eventLog());
    },
    'event failed terminal': (f) {
      f.events.last['success'] = false;
      f.replaceEvents(f.eventLog());
    },
    'event failed test': (f) {
      f.events[2]['result'] = 'error';
      f.replaceEvents(f.eventLog());
    },
    'event unexpected suite': (f) {
      f.events[0]['suite']['path'] = 'test/other_test.dart';
      f.replaceEvents(f.eventLog());
    },
    'event duplicate suite': (f) {
      f.events.insert(1, f.events.first);
      f.replaceEvents(f.eventLog());
    },
    'event after terminal': (f) =>
        f.replaceEvents('${f.eventLog()}{"type":"start"}\n'),
    'event unapproved OS skip': (f) {
      f.events[1]['test']['metadata'] = {'skipReason': 'Host socket errno 9'};
      f.events[2]['skipped'] = true;
      f.source['tests']['passed'] = 0;
      f.replaceEvents(f.eventLog());
    },
  };
  for (final entry in mutations.entries) {
    test('rejects ${entry.key}', () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      entry.value(f);
      // Semantic mutations must agree with the saved receipt, so a mismatch
      // cannot mask validation of argv, suite, exit and timeout fields.
      for (final stage in ['preparation', 'execution']) {
        if (entry.key.startsWith('$stage ')) {
          final name = stage == 'preparation'
              ? 'source-pub-get'
              : 'source-tests';
          File(p.join(f.evidence.path, '$name.json'))
              .writeAsStringSync(jsonEncode(f.source[stage]));
        }
      }
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    });
  }
  for (final fixture in ['git', 'flutter']) {
    for (final change in [
      'environment',
      'missing readiness',
      'hash',
      'extra readiness',
    ]) {
      test('rejects $fixture $change', () async {
        final f = Fixture('linux-x64');
        addTearDown(f.close);
        final manifest = f.proof['acceptance']['fixtures']['manifest'];
        final readiness = manifest['readiness']['$fixture-fixture'];
        switch (change) {
          case 'environment':
            manifest['environment']['ARCHWAY_${fixture == 'git' ? 'PUB_GIT' : 'FLUTTER'}_FIXTURE'] =
                'elsewhere';
          case 'missing readiness':
            readiness.remove('pubspec.lock');
          case 'hash':
            readiness['pubspec.lock'] = 'A' * 64;
          case 'extra readiness':
            readiness['extra'] = 'a' * 64;
        }
        await expectLater(f.validate(), throwsA(isA<FormatException>()));
      });
    }
  }
  test('untracked files do not enlarge exact tracked inventory', () async {
    final f = Fixture('linux-x64');
    addTearDown(f.close);
    f.writeTracked('test/untracked_test.dart', 'not tracked');
    await f.validate();
  });
  test(
    'hash-consistent substituted snapshot is rejected against Git bytes',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      final inventory = jsonDecode(
        File(p.join(f.evidence.path, 'source-files.json')).readAsStringSync(),
      );
      inventory['pubspec.lock'] = '0' * 64;
      f.rewriteSnapshot(jsonEncode(inventory));
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );
  test(
    'linked tracked file cannot stand in for ordinary snapshot source',
    () async {
      final f = Fixture('linux-x64');
      addTearDown(f.close);
      final lock = File(p.join(f.repo.path, 'pubspec.lock'));
      final outside = lock.copySync(p.join(f.root.path, 'outside.lock'));
      lock.deleteSync();
      Link(lock.path).createSync(outside.path);
      await expectLater(f.validate(), throwsA(isA<FormatException>()));
    },
  );

  test('rejects Windows root-relative snapshots without a drive', () async {
    final fixture = Fixture('windows-x64');
    addTearDown(fixture.close);
    fixture.source['snapshot_root'] = r'\temporary\source';
    await expectLater(fixture.validate(), throwsA(isA<FormatException>()));
  });
}
