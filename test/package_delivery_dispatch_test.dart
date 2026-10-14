// Execute the actual workflow shell boundary with a failing public CLI operand.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  for (final channel in ['npm', 'pub']) {
    test(
      '$channel workflow forwards closed arguments and preserves CLI failure through tee',
      () async {
        final workflow = loadYaml(
          File('.github/workflows/package-delivery-probe.yml')
              .readAsStringSync(),
        ) as Map;
        final owner = channel == 'npm'
            ? 'tool/npm/installed_probe.dart'
            : 'tool/ci/pub_installed_route.dart';
        final step =
            ((workflow['jobs']['$channel-installed']['steps'] as List)
                    .cast<Map>())
                .singleWhere((step) => '${step['run']}'.contains(owner));
        final script = (step['run'] as String)
            .replaceAll(r'${{ matrix.target }}', 'linux-x64')
            .replaceAll(r'${{ matrix.route }}', 'cache');
        final root = Directory(
          Directory.systemTemp
              .createTempSync('workflow dispatch café-')
              .resolveSymbolicLinksSync(),
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final registry = File(
          p.join(root.path, 'tool/ci/registry_candidate_arguments.sh'),
        );
        registry.parent.createSync(recursive: true);
        File('tool/ci/registry_candidate_arguments.sh').copySync(registry.path);
        for (final name in [
          'runner',
          'build/npm-local',
          'build/pub-installed',
          'acquisition-input',
        ]) {
          Directory(p.join(root.path, name)).createSync(recursive: true);
        }
        File(p.join(root.path, 'acquisition-input/acquisition.json'))
            .writeAsStringSync('{"version":"2.3.4"}');
        final captured = File(p.join(root.path, 'original-argv.jsonl'));
        final fake = File(p.join(root.path, 'dart operand'))
          ..writeAsStringSync('''#!/usr/bin/env bash
node -e 'require("node:fs").appendFileSync(process.env.OBSERVED_ARGV, JSON.stringify(process.argv.slice(1))+"\\n")' "\$@"
exit 37
''');
        expect(Process.runSync('chmod', ['+x', fake.path]).exitCode, 0);
        const expectedTransport = r'{"literal":"café & $(touch INJECTED)"}';
        for (final intent in [
          'true',
          'false',
          '',
          'TRUE',
          '1',
          'null',
          '"true"',
          'false; echo unsafe',
        ]) {
          if (captured.existsSync()) captured.deleteSync();
          final result = await Process.run(
            Platform.environment['ARCHWAY_TEST_BASH'] ?? 'bash',
            ['-c', script],
            workingDirectory: root.path,
            environment: {
              ...Platform.environment,
              'OBSERVED_ARGV': captured.path,
              'PUB_DART': fake.path,
              'PUB_BOOTSTRAP_DART': fake.path,
              'PUB_PREPARED_CACHE': p.join(root.path, 'cache café'),
              'GITHUB_WORKSPACE': root.path,
              'GITHUB_SHA': 'c' * 40,
              'GITHUB_RUN_ID': '123',
              'GITHUB_RUN_ATTEMPT': '2',
              'RUNNER_TEMP': p.join(root.path, 'runner'),
              'ARCHWAY_REGISTRY_READY': intent,
              'ARCHWAY_WRONG_NODE': p.join(root.path, 'wrong node'),
              'EXPECTED_PUB_TRANSPORT': expectedTransport,
            },
          ).timeout(const Duration(seconds: 20));
          if (intent != 'true' && intent != 'false') {
            expect(result.exitCode, 1);
            expect(
              result.stderr,
              contains('Registry candidate intent must be true or false'),
            );
            expect(result.stdout, isEmpty);
            expect(captured.existsSync(), isFalse);
            continue;
          }
          expect(
            result.exitCode,
            37,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final rows = captured.readAsLinesSync();
          expect(
            rows.length,
            1,
            reason: 'A failed owner must stop later source checks',
          );
          final args = (jsonDecode(rows.single) as List).cast<String>();
          expect(args.take(2), ['run', owner]);
          final options = <String, String?>{};
          for (var index = 2; index < args.length; index++) {
            final name = args[index];
            expect(options.containsKey(name), isFalse);
            options[name] = ['--ci-host', '--registry-ready'].contains(name)
                ? null
                : args[++index];
          }
          final npmCli = channel == 'npm' ? options.remove('--npm-cli') : null;
          final expected = <String, String?>{
            '--target': 'linux-x64',
            '--ci-host': null,
            if (intent == 'true') '--registry-ready': null,
            '--wrong-node': p.join(root.path, 'wrong node'),
            '--native-archive': p.join(
              root.path,
              'native-input/archway-2.3.4-linux-x64.tar.gz',
            ),
            '--output': p.join(root.path, 'runner/archway-$channel-probe'),
            if (channel == 'npm') ...{
              '--packed-directory': p.join(root.path, 'npm-input'),
              '--expected-commit': 'c' * 40,
              '--route': 'cache',
            } else ...{
              '--source': root.path,
              '--expected-source': 'c' * 40,
              '--run-id': '123',
              '--run-attempt': '2',
              '--transport': p.join(root.path, 'pub-input/installation.tar'),
              '--expected-json': expectedTransport,
              '--descriptor': p.join(
                root.path,
                'acquisition-input/acquisition.json',
              ),
              '--prepared-cache': p.join(root.path, 'cache café'),
            },
          };
          expect(options, expected);
          if (channel == 'npm') {
            final npm = File(npmCli!);
            expect(p.basename(npm.path), 'npm-cli.js');
            expect(npm.resolveSymbolicLinksSync(), npm.path);
            final metadata = jsonDecode(
              File(p.join(npm.parent.parent.path, 'package.json'))
                  .readAsStringSync(),
            ) as Map;
            expect(metadata['version'], '11.19.0');
          }
          expect(File(p.join(root.path, 'INJECTED')).existsSync(), isFalse);
        }
      },
      skip: Platform.isWindows
          ? 'POSIX shell dispatch; native Windows workflow remains required'
          : false,
    );
  }
}
