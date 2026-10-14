// Complete synthetic twelve-route inventory with independent original streams.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'npm_expanded_receipt_fixtures.dart';
import 'npm_termination_receipt_fixtures.dart';
import 'pub_receipt_fixtures.dart';

Map<String, dynamic> installedRouteFixture(
  Directory root,
  Map<String, Object?> source,
  String npmSha256, {
  bool registryReady = false,
}) {
  final transport = <String, dynamic>{
    'schema_version': registryReady ? 2 : 1,
    'source': source,
    'file_set_sha256': 'e' * 64,
    'archive': {'sha256': 'f' * 64, 'size': 10},
    'run_id': '123',
    'run_attempt': '1',
    if (registryReady) ...{
      'registry_ready': true,
      'upload_archive': {
        'sha256': '1' * 64,
        'size': 9,
        'unpacked_bytes': 8,
        'files': 1,
      },
    },
  };
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    for (final route in ['local', 'global', 'cache']) {
      final directory = Directory(
        p.join(root.path, 'npm', 'npm-installed-$route-$target-123-1'),
      )..createSync(recursive: true);
      final expanded = npmExpandedFixture(directory, target, route);
      final receipt = {
        'registry_ready': registryReady,
        'target': target,
        'source_commit': source['commit'],
        'run_id': '123',
        'run_attempt': '1',
        'route': {
          'local': 'local-devDependency',
          'global': 'global-prefix',
          'cache': 'npm-exec-cache',
        }[route],
        'tarball_sha256': npmSha256,
        'node': [
          'v24.21.0',
          {
            'linux-x64': 'linux',
            'macos-arm64': 'darwin',
            'windows-x64': 'win32',
          }[target],
          target == 'macos-arm64' ? 'arm64' : 'x64',
        ],
        'npm': '11.19.0',
        'cases': [
          for (final phase
              in route == 'cache' ? ['cached'] : ['installed', 'relocated'])
            {
              'phase': phase,
              'help': 0,
              'version': 0,
              'init': 0,
              'analysis': [
                for (final entry in const {
                  'clean': 0,
                  'dependency-violation': 1,
                  'unsupported-option': 64,
                  'missing-owned-helper': 2,
                  'restored-clean': 0,
                }.entries)
                  {'case': entry.key, 'exit': entry.value},
              ],
              ...expanded,
              ...terminationFixture(target, route),
            },
        ],
      };
      File(p.join(directory.path, 'report.json'))
          .writeAsStringSync(jsonEncode(receipt));
    }
    final directory = Directory(
      p.join(root.path, 'pub', 'pub-installed-$target-123-1', 'nested'),
    )..createSync(recursive: true);
    final receipt = {
      'registry_ready': registryReady,
      'target': target,
      'source': source,
      'transport': transport,
      'file_set_sha256': transport['file_set_sha256'],
      'phases': {
        for (final phase in ['installed', 'poisoned_source_snapshot'])
          phase: {
            'commands': [
              for (final args in [
                ['--help'],
                ['--version'],
                ['init', '--template', 'mixed'],
              ])
                {'arguments': args, 'exit': 0},
            ],
          },
      },
      ...pubReceiptFixture(directory, target),
    };
    File(p.join(directory.path, 'report.json'))
        .writeAsStringSync(jsonEncode(receipt));
  }
  return transport;
}
