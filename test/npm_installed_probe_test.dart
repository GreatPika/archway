import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import 'support/native_process_support.dart';
import '../tool/npm/installed_route.dart';

void main() {
  late Directory root;
  setUp(
    () => root = Directory(
      Directory.systemTemp
          .createTempSync('npm-owner-')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'local route refuses outside-project installation before npm invocation',
    () {
      final project = Directory(p.join(root.path, 'project'))..createSync();
      final logs = Directory(p.join(root.path, 'logs'))..createSync();
      final archive = File(p.join(root.path, 'candidate.tgz'))
        ..writeAsStringSync('ordinary');
      final recorder = InstalledCommandRecorder(output: logs);
      expect(
        () => NpmInstalledRoute(
          route: 'local',
          archive: archive,
          node: archive,
          npmCli: archive,
          project: project,
          installation: Directory(p.join(root.path, 'outside')),
          environment: {},
          recorder: recorder,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'Local npm installation must be the inspected project',
          ),
        ),
      );
      expect(logs.listSync(), isEmpty);
      expect(recorder.commands, isEmpty);
      expect(Directory(p.join(root.path, 'outside')).existsSync(), isFalse);
    },
  );
  test('outer probe preserves original runtime rejection evidence before installing', () async {
    final discovered = await Process.run('node', ['-p', 'process.execPath']);
    expect(discovered.exitCode, 0);
    final node = File((discovered.stdout as String).trim());
    final observedEnvironment = File(
      p.join(root.path, 'runtime-environment.json'),
    );
    final npm = File(p.join(root.path, 'wrong-npm.cjs'))
      ..writeAsStringSync('''
const selected = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  ['home', 'userprofile', 'localappdata', 'xdg_cache_home'].includes(key.toLowerCase())));
require('node:fs').writeFileSync(${jsonEncode(observedEnvironment.path)}, JSON.stringify(selected));
console.log('0.0.0');
''');
    final packed = Directory(p.join(root.path, 'packed'))..createSync();
    final archive = File(
      p.join(packed.path, 'archway-architecture-cli-0.2.0.tgz'),
    )..writeAsStringSync('must not install');
    File(p.join(packed.path, 'npm-packed.json')).writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'version': '0.2.0',
        'source': {'commit': 'a' * 40},
        'registry_ready': false,
        'filename': p.basename(archive.path),
        'compressed_bytes': archive.lengthSync(),
        'sha256': sha256.convert(archive.readAsBytesSync()).toString(),
        'descriptor_sha256': 'b' * 64,
        'stage_inventory_sha256': 'c' * 64,
      }),
    );
    for (final (route, seconds) in [('global', 30), ('cache', 120)]) {
      final output = Directory(p.join(root.path, 'proof-$route'));
      final execution = await runNativeProcess(
        [
          Platform.resolvedExecutable,
          p.join(Directory.current.path, 'tool/npm/installed_probe.dart'),
          '--packed-directory',
          packed.path,
          '--expected-commit',
          'a' * 40,
          '--target',
          nativeTarget().target,
          '--route',
          route,
          '--npm-cli',
          npm.path,
          '--wrong-node',
          node.path,
          '--output',
          output.path,
        ],
        timeout: const Duration(seconds: 90),
        environment: {
          ...Platform.environment,
          'hOmE': '/foreign-home',
          'uSeRpRoFiLe': '/foreign-profile',
          'lOcAlApPdAtA': '/foreign-cache',
          'xDg_CaChE_hOmE': '/foreign-xdg',
        },
      );
      final selectedEnvironment =
          jsonDecode(observedEnvironment.readAsStringSync()) as Map;
      expect(selectedEnvironment.keys.toSet(), {
        'HOME',
        'USERPROFILE',
        'LOCALAPPDATA',
        'XDG_CACHE_HOME',
      });
      expect(
        selectedEnvironment['HOME'],
        p.join(output.path, 'npm installed café', 'home'),
      );
      expect(selectedEnvironment['USERPROFILE'], selectedEnvironment['HOME']);
      expect(execution.exitCode, 1);
      expect(
        utf8.decode(execution.stderr),
        contains('Wrong pinned npm runtime'),
      );
      final report = jsonDecode(
        File(p.join(output.path, 'report.json')).readAsStringSync(),
      );
      expect(report['status'], 'failed');
      expect(report['route'], route);
      expect(report['target'], nativeTarget().target);
      final original = jsonDecode(
        File(p.join(output.path, 'processes/installed-0.json'))
            .readAsStringSync(),
      );
      expect(original['timeout_seconds'], seconds);
      expect(original['timed_out'], false);
      expect(report['processes'], hasLength(1));
      expect(report['processes'][0]['arguments'], [
        node.path,
        npm.path,
        '--version',
      ]);
      expect(
        File(
          p.join(
            output.path,
            'processes',
            report['processes'][0]['stdout'] as String,
          ),
        ).readAsStringSync(),
        '0.0.0\n',
      );
      expect(
        Directory(
          p.join(output.path, 'npm installed café/project/node_modules'),
        ).existsSync(),
        isFalse,
      );
    }
  });
}
