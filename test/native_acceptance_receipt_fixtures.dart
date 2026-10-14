import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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
