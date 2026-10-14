import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/native_acceptance.dart';
import '../tool/npm/installed_assets.dart';
import 'support/native_process_support.dart';

void main() {
  test('asset controls restore exact helper bytes after an unexpected installed response', () async {
    final base = Directory(
      Directory.systemTemp
          .createTempSync('npm asset controls ')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => base.deleteSync(recursive: true));
    Directory directory(String name) =>
        Directory(p.join(base.path, name))..createSync(recursive: true);
    final payload = directory('separate native payload');
    final binary = File(
      p.join(
        payload.path,
        'bin',
        nativeTarget().target,
        Platform.isWindows ? 'archway.exe' : 'archway',
      ),
    );
    binary.parent.createSync(recursive: true);
    final built = await runNativeProcess([
      Platform.resolvedExecutable,
      'compile',
      'exe',
      p.absolute('test/support/native_installed_command_child.dart'),
      '-o',
      binary.path,
    ], timeout: const Duration(seconds: 90));
    expect(built.exitCode, 0, reason: utf8.decode(built.stderr));
    final helper = File(p.join(payload.path, 'assets/typescript/helper.cjs'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([0, 1, 128, 255, 10]);
    final project = directory('project');
    File(p.join(project.path, 'src/app/main.ts'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('export const value = 1;\n');
    final recorder = InstalledCommandRecorder(output: directory('receipts'));
    final controls = NpmInstalledControls(
      executable: File(p.join(base.path, 'logical npm shim')),
      command: (args) => [binary.path, ...args.skip(1)],
      project: project,
      cwd: directory('foreign'),
      wrapper: directory('wrapper'),
      payload: payload,
      target: nativeTarget().target,
      environment: {...Platform.environment, 'PATH': 'prepared-runtime'},
      recorder: recorder,
    );
    // This existing fixture follows aliases and returns success. It deliberately
    // supplies invalid evidence to the probe; it is not a real-core substitute.
    await expectLater(
      exerciseInstalledAssets(controls),
      throwsA(isA<SuiteExitFailure>()),
    );
    expect(recorder.commands.single['exit'], 0);
    expect(helper.readAsBytesSync(), [0, 1, 128, 255, 10]);
    expect(
      FileSystemEntity.typeSync(helper.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(helper.parent.listSync().map((file) => p.basename(file.path)), [
      'helper.cjs',
    ]);
  });
}
