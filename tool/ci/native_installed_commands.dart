// Bounded native command inspection. Callers own verified runtime/host identity.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'aot_init_assertions.dart';
import 'installed_command_recorder.dart';

Map<String, String> installedRuntimeEnvironment(
  Map<String, String> inherited,
  String runtimeDirectory,
) => {
  for (final entry in inherited.entries)
    if (!{
          'path',
          'node_options',
          'node_path',
          'node_auth_token',
          'npm_token',
        }.contains(entry.key.toLowerCase()) &&
        !entry.key.toLowerCase().startsWith('npm_config_'))
      entry.key: entry.value,
  'PATH': runtimeDirectory,
};

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, Object?> _snapshot(Directory root) => {
  for (final entity in root.listSync(recursive: true, followLinks: false))
    p.relative(entity.path, from: root.path): entity is Link
        ? ['link', entity.targetSync()]
        : entity is Directory
        ? ['directory']
        : [
            'file',
            sha256.convert(File(entity.path).readAsBytesSync()).toString(),
          ],
};

Future<Map<String, Object?>> runInstalledCommands(
  File binary,
  Directory installation,
  Directory base,
  File node,
  InstalledCommandRecorder recorder, {
  bool readOnly = false,
}) async {
  _require(
    installation.resolveSymbolicLinksSync() == installation.path,
    'Installation must be canonical',
  );
  final foreign = Directory(p.join(base.path, 'foreign'))..createSync();
  final noRuntimes = installedRuntimeEnvironment(
    Platform.environment,
    p.join(base.path, 'no-runtime'),
  );
  final help = await recorder.capture(
    [binary.path, '--help'],
    workingDirectory: foreign.path,
    environment: noRuntimes,
  );
  final version = await recorder.capture(
    [binary.path, '--version'],
    workingDirectory: foreign.path,
    environment: noRuntimes,
  );
  _require(
    utf8.decode(help.stdout).startsWith('archway [--root ROOT]') &&
        help.stderr.isEmpty &&
        version.stderr.isEmpty &&
        [
          'archway 0.1.0\n',
          'archway 0.1.0\r\n',
        ].contains(utf8.decode(version.stdout)),
    'Unexpected native help/version',
  );
  final init = Directory(p.join(base.path, 'init'))..createSync();
  await assertAotInit(
    binary,
    init,
    environment: noRuntimes,
    label: 'Native installation',
    run: recorder.capture,
  );
  final policy = p.join(init.path, 'empty project café');
  final valid = await recorder.capture(
    [binary.path, '--root', policy, 'validate'],
    workingDirectory: foreign.path,
    environment: noRuntimes,
  );
  _require(
    jsonDecode(utf8.decode(valid.stdout))['exit_code'] == 0 &&
        valid.stderr.isEmpty,
    'Final native policy validation failed',
  );
  final exported = await recorder.capture(
    [binary.path, '--root', policy, 'export', '--format', 'mermaid'],
    workingDirectory: foreign.path,
    environment: noRuntimes,
  );
  _require(
    utf8.decode(exported.stdout).endsWith('flowchart LR\n') &&
        jsonDecode(utf8.decode(exported.stderr))['exit_code'] == 0,
    'Final native Mermaid export failed',
  );
  final project = Directory(p.join(base.path, 'prepared project'))
    ..createSync();
  final source = File(p.join(project.path, 'src/app/main.ts'));
  final core = File(p.join(project.path, 'src/core/private.ts'));
  const clean = 'export const value = 1;\n';
  for (final file in [source, core]) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(clean);
  }
  File(p.join(project.path, 'tsconfig.json')).writeAsStringSync(
    '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
  );
  File(p.join(project.path, 'architecture.yaml'))
      .writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''');
  final marker = File(p.join(project.path, 'project-decoy-executed'));
  for (final relative in [
    'assets/typescript/helper.cjs',
    'node_modules/typescript/lib/typescript.js',
  ]) {
    final decoy = File(p.join(project.path, relative));
    decoy.parent.createSync(recursive: true);
    decoy.writeAsStringSync(
      "require('node:fs').writeFileSync(${jsonEncode(marker.path)}, 'executed');throw Error('decoy');",
    );
  }
  final cases = <Map<String, Object?>>[];
  Future<void> check(
    String name,
    int code,
    String status, [
    List<String> extra = const [],
  ]) async {
    final before = _snapshot(project),
        cwd = _snapshot(foreign),
        owned = _snapshot(installation);
    final result = await recorder.capture(
      [binary.path, '--root', project.path, 'check', ...extra],
      workingDirectory: foreign.path,
      environment: installedRuntimeEnvironment(
        Platform.environment,
        node.parent.path,
      ),
      expectedExit: code,
    );
    _require(!marker.existsSync(), 'Project decoy executed');
    _require(
      sameJson(_snapshot(project), before) &&
          sameJson(_snapshot(foreign), cwd) &&
          cwd.isEmpty &&
          sameJson(_snapshot(installation), owned),
      'Check unexpectedly changed files',
    );
    _require(
      result.stderr.isEmpty &&
          result.stdout.isNotEmpty &&
          result.stdout.last == 10 &&
          result.stdout.where((b) => b == 10).length == 1 &&
          !sameJson(result.stdout.take(3).toList(), [239, 187, 191]),
      'Unexpected check streams',
    );
    final value = jsonDecode(utf8.decode(result.stdout));
    _require(
      value['schema_version'] == 1 &&
          value['command'] == 'check' &&
          value['exit_code'] == code &&
          value['status'] == status,
      'Unexpected check envelope',
    );
    final payload = value['payload'];
    if (code == 64) {
      _require(payload == null, 'Usage error must have null payload');
    } else {
      _require(
        payload['policy_valid'] == true &&
            payload['analysis_complete'] == (code != 2),
        'Wrong analysis completeness',
      );
      if (code == 2) {
        _require(
          sameJson(
            (payload['tool_errors'] as List).map((e) => e['code']).toList(),
            ['TYPESCRIPT_ASSETS_UNAVAILABLE'],
          ),
          'Unexpected asset failure',
        );
      } else {
        _require(
          value['tool_versions']['typescript'] == '5.9.3' &&
              sameJson(payload['tool_errors'], []) &&
              sameJson(payload['unknowns'], []) &&
              sameJson(payload['observed'], {
                'files': 2,
                'analyzed_files': 2,
                'edges': code,
              }) &&
              sameJson(
                (payload['violations'] as List).map((e) => e['code']).toList(),
                code == 1 ? ['DEPENDENCY_NOT_ALLOWED'] : [],
              ),
          'Unexpected TypeScript analysis',
        );
      }
    }
    cases.add({
      'case': name,
      'command': 'check',
      'exit': result.exitCode,
      'status': status,
      'analysis_complete': payload == null
          ? null
          : payload['analysis_complete'],
    });
  }

  await check('clean', 0, 'ok');
  source.writeAsStringSync("import {value} from '../core/private';\n");
  await check('dependency-violation', 1, 'negative');
  await check('unsupported-option', 64, 'usage_error', ['--unsupported']);
  source.writeAsStringSync(clean);
  if (!readOnly) {
    final helper = File(
      p.join(installation.path, 'assets/typescript/helper.cjs'),
    );
    final original = _snapshot(helper.parent);
    final saved = File('${helper.path}.saved');
    _require(
      FileSystemEntity.typeSync(saved.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Saved helper already exists',
    );
    helper.renameSync(saved.path);
    try {
      await check('missing-owned-helper', 2, 'incomplete');
    } finally {
      saved.renameSync(helper.path);
    }
    _require(
      sameJson(_snapshot(helper.parent), original),
      'Owned helper was not restored exactly',
    );
    await check('restored-clean', 0, 'ok');
  }
  return {
    'native_commands': ['help', 'version', 'init', 'validate', 'export'],
    'typescript': cases,
  };
}
