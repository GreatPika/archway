import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/native_installed_commands.dart';
import '../tool/ci/native_installed_inspection.dart';
import 'support/native_process_support.dart';

void main() {
  late Directory base, installation;
  late File binary;
  setUpAll(() async {
    base = Directory(
      Directory.systemTemp
          .createTempSync('installed-controls-')
          .resolveSymbolicLinksSync(),
    );
    installation = Directory(p.join(base.path, 'installation café'))
      ..createSync();
    binary = File(
      p.join(
        installation.path,
        'bin',
        nativeTarget().target,
        Platform.isWindows ? 'archway.exe' : 'archway',
      ),
    );
    binary.parent.createSync(recursive: true);
    final built = await runNativeProcess([
      Platform.resolvedExecutable,
      '--suppress-analytics',
      'compile',
      'exe',
      p.absolute('test/support/native_installed_command_child.dart'),
      '-o',
      binary.path,
    ], timeout: const Duration(seconds: 90));
    expect(built.exitCode, 0, reason: utf8.decode(built.stderr));
    File(p.join(installation.path, 'assets/typescript/helper.cjs'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('owned fixture helper');
  });
  tearDownAll(() => base.deleteSync(recursive: true));

  test('read-only installed commands retain eight original processes without mutating the installation', () async {
    final work = Directory(p.join(base.path, 'read-only'))..createSync();
    final output = Directory(p.join(base.path, 'logs'))..createSync();
    final recorder = InstalledCommandRecorder(
      output: output,
      timeout: const Duration(seconds: 30),
    );
    final result = await runInstalledCommands(
      binary,
      installation,
      work,
      File(Platform.resolvedExecutable),
      recorder,
      readOnly: true,
    );
    expect(result['native_commands'], [
      'help',
      'version',
      'init',
      'validate',
      'export',
    ]);
    expect((result['typescript'] as List).map((v) => v['case']), [
      'clean',
      'dependency-violation',
      'unsupported-option',
    ]);
    expect(recorder.commands.map((c) => c['exit']), [0, 0, 0, 0, 0, 0, 1, 64]);
    final init = jsonDecode(
      File(p.join(output.path, recorder.commands[2]['stdout'] as String))
          .readAsStringSync(),
    );
    expect(init['payload']['outcome'], 'created');
    expect(
      recorder.commands.map((c) => c['stdout']),
      List.generate(8, (i) => 'installed-$i.stdout.log'),
    );
    expect(
      File(p.join(installation.path, 'assets/typescript/helper.cjs'))
          .readAsStringSync(),
      'owned fixture helper',
    );
  });
  test(
    'relocated archive controls remove and restore only the owned helper',
    () async {
      final work = Directory(p.join(base.path, 'archive'))..createSync();
      final output = Directory(p.join(base.path, 'archive-logs'))..createSync();
      final recorder = InstalledCommandRecorder(
        output: output,
        timeout: const Duration(seconds: 30),
      );
      final result = await runInstalledCommands(
        binary,
        installation,
        work,
        File(Platform.resolvedExecutable),
        recorder,
      );
      expect((result['typescript'] as List).map((v) => v['case']), [
        'clean',
        'dependency-violation',
        'unsupported-option',
        'missing-owned-helper',
        'restored-clean',
      ]);
      expect(recorder.commands.map((c) => c['exit']), [
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        64,
        2,
        0,
      ]);
      expect(
        File(p.join(installation.path, 'assets/typescript/helper.cjs'))
            .readAsStringSync(),
        'owned fixture helper',
      );
    },
  );
  test('synthetic orchestration retains ten installed command receipts and delegates existing suites', () async {
    final work = Directory(p.join(base.path, 'installer'))..createSync();
    final output = Directory(p.join(base.path, 'installer-logs'))..createSync();
    final wrong = File(
      p.join(base.path, 'wrong-node', Platform.isWindows ? 'node.exe' : 'node'),
    );
    wrong.parent.createSync();
    wrong.writeAsStringSync('synthetic runtime placeholder');
    File(p.join(installation.path, 'manifest.json'))
        .writeAsStringSync('controlled manifest');
    final fixtureFile = File(p.join(base.path, 'fixtures.json'))
      ..writeAsStringSync(
        jsonEncode({
          for (final name in [
            'dart_sdk',
            'pub_fixture',
            'git_fixture',
            'flutter_sdk',
            'flutter_fixture',
          ])
            name: base.path,
          'wrong_node': wrong.path,
          'environment': {'ARCHWAY_FIXTURE': 'prepared'},
        }),
      );
    // Unix installers expose an alias outside the archive target directory.
    final selectedCommand = Platform.isWindows
        ? binary
        : File(p.join(base.path, 'usr', 'local', 'bin', 'archway'));
    if (!Platform.isWindows) {
      selectedCommand.parent.createSync(recursive: true);
      Link(selectedCommand.path).createSync(binary.path);
    }
    final suites = <String>[];
    final result = await inspectInstalledCommands(
      selectedCommand,
      installation,
      target: nativeTarget().target,
      repository: Directory.current,
      base: work,
      node: File(Platform.resolvedExecutable),
      fixtureFile: fixtureFile,
      output: output,
      execute:
          (
            name,
            command,
            cwd,
            environment,
            directory, {
            required timeout,
          }) async {
            suites.add(name);
            expect(
              command[3],
              p.absolute('test', '${name}_process_smoke.dart'),
            );
            expect(command[4], selectedCommand.path);
            expect(environment['ARCHWAY_FIXTURE'], 'prepared');
            expect(directory.path, p.join(output.path, 'suites'));
            return {'suite': name, 'synthetic_test_only': true};
          },
    );
    expect((result['processes'] as List).map((c) => c['exit']), [
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      64,
      2,
      2,
    ]);
    expect(result['runtime_controls'], [
      {
        'case': 'missing-node',
        'exit': 2,
        'errors': ['NODE_UNAVAILABLE'],
      },
      {
        'case': 'wrong-node',
        'exit': 2,
        'errors': ['NODE_UNAVAILABLE'],
      },
    ]);
    expect(suites, ['plan_query', 'dart_check']);
    expect(result['binary'], selectedCommand.path);
  });
  test(
    'runtime environment removes case variants of loader and npm influence',
    () {
      expect(
        installedRuntimeEnvironment({
          'Path': 'untrusted',
          'PATH': 'also untrusted',
          'nOdE_oPtIoNs': 'hook',
          'NODE_PATH': 'project',
          'Node_Auth_Token': 'secret',
          'NPM_TOKEN': 'secret',
          'Npm_Config_Prefix': 'untrusted',
          'SystemRoot': 'keep',
          'TMP': 'keep temp',
        }, '/pinned/node'),
        {'SystemRoot': 'keep', 'TMP': 'keep temp', 'PATH': '/pinned/node'},
      );
    },
  );
  for (final fault in [
    'help',
    'init',
    'validate',
    'export',
    'compiler',
    'project-write',
    'foreign-write',
    'missing-helper',
  ]) {
    test(
      'probe rejects $fault evidence and retains original subprocess logs',
      () async {
        final control = File(p.join(installation.path, 'probe-control'))
          ..writeAsStringSync(fault);
        addTearDown(control.deleteSync);
        final work = Directory(p.join(base.path, 'fault-$fault'))..createSync();
        final output = Directory(p.join(base.path, 'logs-$fault'))
          ..createSync();
        final recorder = InstalledCommandRecorder(output: output);
        await expectLater(
          runInstalledCommands(
            binary,
            installation,
            work,
            File(Platform.resolvedExecutable),
            recorder,
          ),
          throwsStateError,
        );
        expect(recorder.commands, isNotEmpty);
        for (final process in recorder.commands) {
          expect(
            File(p.join(output.path, process['stdout'] as String)).existsSync(),
            true,
          );
        }
        expect(
          File(p.join(installation.path, 'assets/typescript/helper.cjs'))
              .readAsStringSync(),
          'owned fixture helper',
        );
      },
    );
  }
}
