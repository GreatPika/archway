// The native fixture deliberately fails version acceptance after real SDK dispatch.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/pub_stage_transport.dart';
import 'support/pub_native_fixture.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  test('private stage uses an exact SDK archive without registry-validation credit', () async {
    final fixture = await preparePubStageFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final compiled = File(
      p.join(
        fixture.root.path,
        'controlled${Platform.isWindows ? '.exe' : ''}',
      ),
    );
    final built = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/native_installed_command_child.dart',
      '-o',
      compiled.path,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    final native = preparePubNativeFixture(fixture, executable: compiled);
    final stage = Directory(p.join(fixture.root.path, 'stage'));
    final staged = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/pub/stage.dart',
      '--source',
      fixture.source.path,
      '--descriptor',
      fixture.descriptor.path,
      '--expected-commit',
      fixture.identity['commit'] as String,
      '--output',
      stage.path,
    ]);
    expect(staged.exitCode, 0, reason: '${staged.stdout}\n${staged.stderr}');
    final transport = Directory(p.join(fixture.root.path, 'transport'));
    final record = await writePubTransport(
      stage,
      fixture.source,
      transport,
      fixture.identity['commit'] as String,
      '123',
      '2',
    );
    Future<ProcessResult> run(String output, {bool registry = false}) =>
        Process.run(Platform.resolvedExecutable, [
          'run',
          'tool/ci/pub_installed_route.dart',
          if (registry) '--registry-ready',
          '--source',
          fixture.source.path,
          '--expected-source',
          fixture.identity['commit'] as String,
          '--run-id',
          '123',
          '--run-attempt',
          '2',
          '--target',
          pubFixtureTarget,
          '--transport',
          p.join(transport.path, 'installation.tar'),
          '--expected-json',
          jsonEncode(record),
          '--descriptor',
          fixture.descriptor.path,
          '--wrong-node',
          Platform.environment['ARCHWAY_TEST_WRONG_NODE'] ??
              'unused-wrong-node',
          '--native-archive',
          native.path,
          '--prepared-cache',
          Platform.environment['PUB_CACHE']!,
          '--output',
          p.join(fixture.root.path, output),
        ]);
    final wrongIntent = await run('wrong-intent', registry: true);
    expect(wrongIntent.exitCode, 1);
    expect(
      wrongIntent.stderr,
      contains('schema or explicit registry intent differs'),
    );
    expect(
      Directory(p.join(fixture.root.path, 'wrong-intent/activation'))
          .existsSync(),
      isFalse,
    );
    final result = await run('private');
    expect(result.exitCode, 1);
    expect(result.stderr, contains('Unexpected native help/version'));
    final output = Directory(p.join(fixture.root.path, 'private'));
    final exported = jsonDecode(
      File(p.join(output.path, 'private-export/installed-0.json'))
          .readAsStringSync(),
    ) as Map;
    expect(exported['command'], [
      File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
      '--suppress-analytics',
      'pub',
      'publish',
      '--to-archive',
      p.join(output.path, 'private-upload.tar.gz'),
      '--skip-validation',
    ]);
    expect(exported['exit_code'], 0);
    final activated = jsonDecode(
      File(p.join(output.path, 'activation/installed-0.json'))
          .readAsStringSync(),
    ) as Map;
    expect((activated['command'] as List).skip(1), [
      '--suppress-analytics',
      'pub',
      'global',
      'activate',
      '--no-executables',
      'archway',
      '0.2.0',
    ]);
    expect(activated['exit_code'], 0);
    final command = jsonDecode(
      File(p.join(output.path, 'execution/installed-1.json'))
          .readAsStringSync(),
    ) as Map;
    expect((command['command'] as List).skip(1), [
      '--suppress-analytics',
      'pub',
      'global',
      'run',
      'archway:archway',
      '--version',
    ]);
    expect(
      File(p.join(output.path, 'execution/installed-1.stdout.log'))
          .readAsStringSync(),
      'archway 0.1.0\n',
    );
    expect(File(p.join(output.path, 'report.json')).existsSync(), isFalse);
    expect(
      File(p.join(output.path, 'received/report.json')).existsSync(),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
