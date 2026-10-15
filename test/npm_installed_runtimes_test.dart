import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/npm/installed_assets.dart';
import '../tool/npm/installed_runtimes.dart';
import 'support/native_process_support.dart';

void main() {
  test('runtime control rejects the genuine supported Node before invoking the route', () async {
    final resolved = await Process.run(
      Platform.environment['ARCHWAY_TEST_NODE'] ?? 'node',
      ['-p', 'process.execPath'],
    );
    expect(resolved.exitCode, 0);
    final node = File(
      File((resolved.stdout as String).trim()).resolveSymbolicLinksSync(),
    );
    final base = Directory(
      Directory.systemTemp
          .createTempSync('npm runtime controls ')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => base.deleteSync(recursive: true));
    Directory directory(String name) =>
        Directory(p.join(base.path, name))..createSync();
    final recorder = InstalledCommandRecorder(output: directory('receipts'));
    final controls = NpmInstalledControls(
      executable: File(p.join(base.path, 'not invoked')),
      command: (_) => throw StateError('Wrong runtime reached installed route'),
      project: directory('project'),
      cwd: directory('foreign'),
      wrapper: directory('wrapper'),
      payload: directory('payload'),
      target: nativeTarget().target,
      environment: Platform.environment,
      recorder: recorder,
    );
    await expectLater(
      verifyInstalledWrongNode(controls, node),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          'Wrong negative-control runtime: expected genuine Node 24.19.0 for ${controls.target}',
        ),
      ),
    );
    final proof = recorder.commands.single;
    final identity = jsonDecode(
      File(p.join(recorder.output.path, proof['stdout'] as String))
          .readAsStringSync(),
    );
    expect(identity[0], 'v24.21.0');
    expect(
      File(p.join(recorder.output.path, proof['stderr'] as String))
          .readAsBytesSync(),
      isEmpty,
    );
  });
  test('Node absence uses the actual caller route without a direct-native fallback', () async {
    final base = Directory(
      Directory.systemTemp
          .createTempSync('route runtime controls ')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => base.deleteSync(recursive: true));
    Directory directory(String name) =>
        Directory(p.join(base.path, name))..createSync(recursive: true);
    final binary = File(
      p.join(
        directory('fixture/bin/${nativeTarget().target}').path,
        Platform.isWindows ? 'archway.exe' : 'archway',
      ),
    );
    final built = await runNativeProcess([
      Platform.resolvedExecutable,
      'compile',
      'exe',
      p.absolute('test/support/native_installed_command_child.dart'),
      '-o',
      binary.path,
    ], timeout: const Duration(seconds: 90));
    expect(built.exitCode, 0, reason: utf8.decode(built.stderr));
    final recorder = InstalledCommandRecorder(output: directory('receipts'));
    final environment = {
      ...Platform.environment,
      'PATH': '${base.path}/no-runtime',
    };
    final controls = NpmInstalledControls(
      executable: File(p.join(base.path, 'logical SDK route')),
      command: (args) => [binary.path, ...args.skip(1)],
      project: directory('project'),
      cwd: directory('foreign'),
      wrapper: directory('wrapper'),
      payload: directory('no direct binary'),
      target: nativeTarget().target,
      environment: environment,
      recorder: recorder,
    );
    final cases = await exerciseInstalledNodeAbsence(
      controls,
      environment: environment,
    );
    expect(cases.map((item) => item['invocation']), [
      'installed-route',
      'installed-route',
    ]);
    expect(recorder.commands.map((item) => item['exit']), [2, 0]);
  });
}
