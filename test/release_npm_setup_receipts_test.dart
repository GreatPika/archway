import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/release_installed_process_receipts.dart';
import '../tool/ci/release_npm_setup_receipts.dart';
import '../tool/npm/native_preparation_command.dart';

InstalledProcessEvidence capture(List<String> args, [String stdout = '']) => (
  arguments: args,
  exitCode: 0,
  stdout: utf8.encode(stdout),
  stderr: <int>[],
);

void main() {
  test(
    'private setup binds production preparation program and exact route',
    () {
      final proof = <String, dynamic>{
        'node_executable': '/runtime/node',
        'npm_cli': '/runtime/npm-cli.js',
        'archive_path': '/owned/archway-architecture-cli-0.2.0.tgz',
      };
      final phase = <String, dynamic>{
        'command_prefix': ['/project/node_modules/.bin/archway'],
        'project': '/project',
        'wrapper': '/project/node_modules/archway-architecture-cli',
        'payload': '/cache/npm/0.2.0/linux-x64/.archway-native-owned',
      };
      final records = [
        capture([
          '/runtime/node',
          '/runtime/npm-cli.js',
          '--version',
        ], '11.19.0\n'),
        capture([
          '/runtime/node',
          '/runtime/npm-cli.js',
          'install',
          '-D',
          '--prefix',
          '/project',
          proof['archive_path'] as String,
          '--offline',
          '--ignore-scripts',
          '--no-audit',
          '--no-fund',
        ]),
        capture([
          '/runtime/node',
          '--eval',
          npmNativePreparationProgram,
          '/project/node_modules/archway-architecture-cli/bin/cache.cjs',
          '/project/node_modules/archway-architecture-cli/acquisition.json',
          'linux-x64',
          '/cache/npm',
          '/owned/snapshot/input',
        ]),
        capture([
          '/project/node_modules/.bin/archway',
          '--help',
        ], 'archway [--root ROOT] COMMAND\n'),
      ];
      void admit(
        List<InstalledProcessEvidence> rows, {
        String mode = 'ci-verified-native',
      }) => validateNpmSetupProcesses(
        rows,
        proof,
        phase,
        route: 'local',
        target: 'linux-x64',
        acquisitionMode: mode,
      );
      admit(records);
      for (final replacement in [
        'process.exit(0)',
        '$npmNativePreparationProgram\n// changed',
      ]) {
        final args = [...records[2].arguments]..[2] = replacement;
        expect(
          () => admit([...records]..[2] = capture(args)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'owner',
              'Private verified-native preparation command differs',
            ),
          ),
        );
      }
      final outside = [...records[1].arguments]..[5] = '/other';
      expect(
        () => admit([...records]..[1] = capture(outside)),
        throwsFormatException,
      );
      expect(
        () => admit(records, mode: 'public-https-cold'),
        throwsFormatException,
      );
      admit([records[0], records[1], records[3]], mode: 'public-https-cold');
    },
  );
}
