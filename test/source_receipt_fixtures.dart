import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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
    final node = windows
        ? r'C:\fixtures\node\node.exe'
        : '/fixtures/node/bin/node';
    final snapshotRoot = windows ? r'C:\temporary\source' : '/temporary/source';
    final npm = windows
        ? paths.join(
            paths.dirname(node),
            'node_modules',
            'npm',
            'bin',
            'npm-cli.js',
          )
        : '/fixtures/node/lib/node_modules/npm/bin/npm-cli.js';
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
      'snapshot_root': snapshotRoot,
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
      'npm_preparation': execution('source-npm-ci', [
        node,
        npm,
        'ci',
        '--prefix',
        paths.join(snapshotRoot, 'tool', 'npm'),
        '--offline',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
      ], ''),
      if (windows)
        'process_preparation': execution('source-windows-process-support', [
          dart,
          '--suppress-analytics',
          'run',
          'tool/ci/prepare_windows_process_support.dart',
        ], ''),
      'execution': execution(
        'source-tests',
        [dart, 'test', '--reporter=json', '--concurrency=2'],
        eventLog(),
        timeout: 1500,
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
        'node_path': node,
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

  void bindNpmSnapshot() {
    final command = List<String>.from(source['npm_preparation']['command']);
    final paths = p.Context(
      style: proof['target'] == 'windows-x64' ? p.Style.windows : p.Style.posix,
    );
    command[4] = paths.join(source['snapshot_root'] as String, 'tool', 'npm');
    source['npm_preparation'] = execution('source-npm-ci', command, '');
  }

  void replaceEvents(String text) {
    source['execution'] = execution(
      'source-tests',
      List<String>.from(source['execution']['command']),
      text,
      timeout: 1500,
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
