import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_native_acceptance_receipts.dart';

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
  test(
    'rejects an aliased original fixture manifest',
    () {
      final e = Evidence('linux-x64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      final file = File(p.join(e.root.path, 'acceptance-fixtures.json'));
      final moved = file.renameSync(
        p.join(e.root.path, 'fixture-original.json'),
      );
      Link(file.path).createSync(moved.path);
      expect(
        () => validateNative(e.proof, e.report, e.root, e.source),
        throwsFormatException,
      );
    },
    skip: Platform.isWindows ? 'Symlink permission differs on Windows' : false,
  );
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

class Evidence {
  Evidence(this.target) {
    root = Directory.systemTemp.createTempSync('native-receipts-');
    report = File(p.join(root.path, 'native.json'));
    directory = Directory(p.join(root.path, 'acceptance'))..createSync();
    final windows = target == 'windows-x64';
    paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    String at(String name) =>
        windows ? 'C:\\evidence\\$name' : '/evidence/$name';
    final harness = at('source'), output = at('output'), node = at('node');
    final sdk = at('dart-sdk'), installed = at('relocated');
    final binary = paths.join(
      installed,
      'bin',
      target,
      windows ? 'archway.exe' : 'archway',
    );
    final fixtures = <String, Object?>{
      'schema_version': 1,
      'source': source,
      'target': target,
      'dart_sdk': sdk,
      'wrong_node': at('wrong-node'),
      'pub_fixture': at('pub'),
      'git_fixture': at('git-fixture'),
      'flutter_sdk': at('flutter'),
      'flutter_fixture': at('flutter-fixture'),
      'environment': {
        'ARCHWAY_PUB_GIT_FIXTURE': at('git-fixture'),
        'ARCHWAY_FLUTTER_FIXTURE': at('flutter-fixture'),
      },
      'pins': {
        'dart': '3.13.3',
        'collection': '1.19.1',
        'git': {
          'url': 'https://github.com/dart-lang/core.git',
          'ref': '4d80610a878cdb3f9f10e6a16a2af6631251a3c6',
        },
        'flutter': {
          'version': '3.47.4',
          'archive': flutterPins[target]![0],
          'sha256': flutterPins[target]![1],
        },
        'wrong_node': {'version': '24.19.0', 'sha256': nodeHashes[target]},
      },
      'readiness': {
        for (final name in [
          'pub/hosted',
          'pub/path',
          'pub/workspace',
          'git-fixture',
          'flutter-fixture',
        ])
          name: {
            for (final file in [
              'pubspec.yaml',
              'pubspec.lock',
              '.dart_tool/package_config.json',
            ])
              file: 'a' * 64,
          },
      },
    };
    final extra = <List<String>>[
      [],
      [],
      [],
      [node],
      [sdk, node, '--existing-installation'],
      [sdk, node],
      [node],
      [node],
      [node],
      [sdk],
      [node],
      [node, paths.join(output, 'runtime-request-coverage.json')],
      [node, at('wrong-node'), sdk],
      [],
      [],
      [],
      [
        harness,
        at('pub'),
        at('git-fixture'),
        paths.join(output, 'package-provenance'),
      ],
      [at('flutter'), at('flutter-fixture')],
    ];
    final suites = <Map<String, Object?>>[];
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final receipt = <String, Object?>{
        'suite': name,
        'command': [
          paths.join(sdk, 'bin', windows ? 'dart.exe' : 'dart'),
          '--suppress-analytics',
          'run',
          paths.join(harness, 'test', '${name}_process_smoke.dart'),
          binary,
          ...extra[i],
        ],
        'exit_code': 0,
        'timed_out': false,
        'timeout_seconds': 600,
        'elapsed_seconds': 0.25,
        for (final stream in ['stdout', 'stderr']) ...{
          stream: '$name.$stream.log',
          '${stream}_sha256': sha256
              .convert(utf8.encode('$name $stream'))
              .toString(),
        },
      };
      for (final stream in ['stdout', 'stderr']) {
        File(p.join(directory.path, '$name.$stream.log'))
            .writeAsStringSync('$name $stream');
      }
      suites.add(receipt);
      File(p.join(directory.path, '$name.json'))
          .writeAsStringSync(jsonEncode(receipt));
    }
    proof = {
      'target': target,
      'source': source,
      'source_root': harness,
      'node': [
        'v24.21.0',
        {
          'linux-x64': 'linux',
          'macos-arm64': 'darwin',
          'windows-x64': 'win32',
        }[target],
        target == 'macos-arm64' ? 'arm64' : 'x64',
      ],
      'relocation': {
        'extracted': at('extracted'),
        'executed': installed,
        'original_removed': true,
      },
      'acceptance': {
        'scope': 'Complete applicable final native archive process suites',
        'source': source,
        'source_root': harness,
        'node_path': node,
        'output_root': output,
        'fixtures': {'manifest': fixtures, 'sha256': ''},
        'suites': suites,
        'source_suite': <String, Object?>{},
      },
    };
    saveFixture();
  }
  final String target;
  late final Directory root, directory;
  late final File report;
  late final p.Context paths;
  late final Map<String, Object?> proof;
  final source = <String, Object?>{
    'commit': 'b' * 40,
    'tree': 'c' * 40,
    'lockfile_sha256': {
      'pubspec.lock': 'd' * 64,
      'assets/typescript/package-lock.json': 'e' * 64,
    },
  };
  Map<String, Object?> get acceptance =>
      proof['acceptance'] as Map<String, Object?>;
  Map<String, Object?> get fixture =>
      (acceptance['fixtures'] as Map)['manifest'] as Map<String, Object?>;
  void saveFixture() {
    final bytes = utf8.encode(jsonEncode(fixture));
    File(p.join(root.path, 'acceptance-fixtures.json')).writeAsBytesSync(bytes);
    (acceptance['fixtures'] as Map)['sha256'] = sha256
        .convert(bytes)
        .toString();
  }
}

const names = [
  'plan_query',
  'cli',
  'catalogue_export',
  'check',
  'dart_check',
  'physical_path',
  'alias_wire',
  'alias_hop_recheck',
  'alias_trace_gap',
  'dart_resource',
  'runtime',
  'runtime_request',
  'runtime_preflight',
  'native_asset',
  'native_abi',
  'native_fault',
  'package_provenance',
  'dart_flutter',
];
const flutterPins = {
  'linux-x64': [
    'stable/linux/flutter_linux_3.47.4-stable.tar.xz',
    '5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3',
  ],
  'macos-arm64': [
    'stable/macos/flutter_macos_arm64_3.47.4-stable.zip',
    'c6af6fa1d64946167b8637ba4c5a7bb3b8574729a1ebe931decd4924dbab7061',
  ],
  'windows-x64': [
    'stable/windows/flutter_windows_3.47.4-stable.zip',
    '31173300481bd06e377fd55ee84214689648b1817563efd7b450b7b78bdf351a',
  ],
};
const nodeHashes = {
  'linux-x64':
      'f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4',
  'macos-arm64':
      '8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d',
  'windows-x64':
      '57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73',
};
