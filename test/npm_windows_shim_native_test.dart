// Native Windows harness capability. This argv echo package is not Archway core acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/native_release_host.dart';
import '../tool/npm/installed_route.dart';

void main() {
  test(
    'actual npm local global and exec Windows shims preserve literal argv under owned capture',
    () async {
      final runtime = await nativeReleaseNode('windows-x64');
      final node = runtime.executable;
      final npm = File(
        p.join(node.parent.path, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
      );
      final root = Directory(
        Directory.systemTemp
            .createTempSync('npm cmd 100% café 😀 ')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final package = Directory(p.join(root.path, 'package'))..createSync();
      final marker = File(p.join(root.path, 'should-not-exist'));
      File(p.join(package.path, 'package.json')).writeAsStringSync(
        jsonEncode({
          'name': 'archway-architecture-cli',
          'version': '1.0.0',
          'private': true,
          'bin': {'archway': 'bin/args.cjs'},
        }),
      );
      File(p.join(package.path, 'bin/args.cjs'))
        ..parent.createSync()
        ..writeAsStringSync('''#!/usr/bin/env node
process.stdout.write(JSON.stringify(process.argv.slice(2))+'\\n');
process.stderr.write('fixture stderr\\n');process.exitCode=23;
''');
      final environment = Map<String, String>.from(Platform.environment)
        ..removeWhere(
          (key, _) =>
              [
                'path',
                'comspec',
                'node_options',
                'node_path',
                'node_auth_token',
                'npm_token',
              ].contains(key.toLowerCase()) ||
              key.toLowerCase().startsWith('npm_config_'),
        );
      environment.addAll({
        'PATH': node.parent.path,
        'ARCHWAY_EXPANSION': 'EXPANDED-NOT-LITERAL',
        'npm_config_cache': p.join(root.path, 'cache'),
        'npm_config_offline': 'true',
        'npm_config_ignore_scripts': 'true',
        'npm_config_audit': 'false',
        'npm_config_fund': 'false',
        'npm_config_registry': 'http://127.0.0.1:9',
      });
      for (final name in ['userconfig', 'globalconfig']) {
        final config = File(p.join(root.path, '$name.npmrc'))
          ..writeAsStringSync('');
        environment['npm_config_$name'] = config.path;
      }
      final recorder = InstalledCommandRecorder(
        output: Directory(p.join(root.path, 'logs'))..createSync(),
        timeout: const Duration(seconds: 120),
      );
      final packed = await recorder.capture(
        [
          node.path,
          npm.path,
          'pack',
          '--offline',
          '--ignore-scripts',
          '--json',
          '--pack-destination',
          root.path,
        ],
        workingDirectory: package.path,
        environment: environment,
      );
      final archive = p.join(
        root.path,
        (jsonDecode(utf8.decode(packed.stdout)) as List).single['filename']
            as String,
      );
      final values = [
        '',
        'space\tpath',
        'café😀',
        '"quoted"',
        r'trailing\',
        r'quoted "end\',
        r'backslash\\\"quote',
        '&',
        '|',
        '<',
        '>',
        '^',
        '(',
        ')',
        '%ARCHWAY_EXPANSION%',
        '!ARCHWAY_EXPANSION!',
        '& echo injected > "${marker.path}"',
        'mixed"^%!&',
      ];
      for (final route in ['local', 'global', 'cache']) {
        final prefix = Directory(p.join(root.path, '$route prefix ü'))
          ..createSync();
        File(p.join(prefix.path, 'package.json'))
            .writeAsStringSync('{"private":true}');
        final installed = NpmInstalledRoute(
          route: route,
          archive: File(archive),
          node: node,
          npmCli: npm,
          project: prefix,
          installation: prefix,
          environment: Map<String, String>.from(environment),
          recorder: recorder,
        );
        await installed.install();
        expect(
          installed.systemCmd,
          File(installed.systemCmd).resolveSymbolicLinksSync(),
        );
        expect(installed.shim.path, installed.shim.resolveSymbolicLinksSync());
        expect(
          installed.packageRoot.path,
          installed.packageRoot.resolveSymbolicLinksSync(),
        );
        final logical = installed.invocation(values);
        final raw = installed.windowsCommandFor(logical);
        final result = await recorder.capture(
          logical,
          windowsCommand: raw,
          workingDirectory: prefix.path,
          environment: installed.environment,
          expectedExit: 23,
        );
        expect(jsonDecode(utf8.decode(result.stdout)), values, reason: route);
        expect(utf8.decode(result.stderr), 'fixture stderr\n', reason: route);
        expect(marker.existsSync(), false);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isWindows
        ? 'Requires genuine Windows npm shims and owned raw-command execution.'
        : false,
  );
}
