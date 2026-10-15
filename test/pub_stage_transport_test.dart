// Private physical transport proof; no registry/native-host acceptance claim.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/compiled_tool.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  late File tool;
  setUpAll(() async {
    tool = await prepareCompiledTool('tool/ci/pub_stage_transport.dart');
  });
  late PubStageFixture fixture;
  late Directory stage;
  setUp(() async {
    fixture = await preparePubStageFixture();
    stage = Directory(p.join(fixture.root.path, 'stage'));
    final result = await Process.run(Platform.resolvedExecutable, [
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
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDown(() => fixture.root.deleteSync(recursive: true));
  Future<ProcessResult> invoke(
    String operation,
    String output,
    List<String> options, {
    String run = '123',
    String attempt = '2',
  }) => Process.run(Platform.resolvedExecutable, [
    tool.path,
    operation,
    '--source',
    fixture.source.path,
    '--expected-source',
    fixture.identity['commit'] as String,
    '--run-id',
    run,
    '--run-attempt',
    attempt,
    '--output',
    p.join(fixture.root.path, output),
    ...options,
  ]);
  test(
    'writer and reader bind caller identity and preserve every thin stage byte',
    () async {
      final written = await invoke('write', 'transport', [
        '--stage-evidence',
        stage.path,
      ]);
      expect(
        written.exitCode,
        0,
        reason: '${written.stdout}\n${written.stderr}',
      );
      final record = jsonDecode(written.stdout as String) as Map;
      expect(record['source'], fixture.identity);
      expect(record['run_id'], '123');
      expect(record['run_attempt'], '2');
      expect(record['registry_ready'], isFalse);
      final archive = File(
        p.join(fixture.root.path, 'transport', 'installation.tar'),
      );
      final received = await invoke('read', 'received', [
        '--archive',
        archive.path,
        '--expected-json',
        jsonEncode(record),
      ]);
      expect(
        received.exitCode,
        0,
        reason: '${received.stdout}\n${received.stderr}',
      );
      final original = {
        for (final file in stage.listSync(recursive: true).whereType<File>())
          p.relative(file.path, from: stage.path): file.readAsBytesSync(),
      };
      final output = Directory(p.join(fixture.root.path, 'received'));
      expect(
        output
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.relative(f.path, from: output.path))
            .toSet(),
        original.keys.toSet(),
      );
      for (final entry in original.entries) {
        expect(
          File(p.join(output.path, entry.key)).readAsBytesSync(),
          entry.value,
          reason: entry.key,
        );
      }
      for (final (run, attempt, wrongSource) in [
        ('124', '2', false),
        ('123', '3', false),
        ('123', '2', true),
      ]) {
        final expected = jsonDecode(jsonEncode(record)) as Map;
        if (wrongSource) expected['source']['commit'] = '0' * 40;
        final wrong = await invoke(
          'read',
          'wrong-identity',
          ['--archive', archive.path, '--expected-json', jsonEncode(expected)],
          run: run,
          attempt: attempt,
        );
        expect(wrong.exitCode, 1);
        expect(wrong.stderr, contains('source/run/attempt'));
        expect(
          Directory(p.join(fixture.root.path, 'wrong-identity')).existsSync(),
          isFalse,
        );
      }
      final duplicate = await invoke('read', 'received', [
        '--archive',
        archive.path,
        '--expected-json',
        jsonEncode(record),
      ]);
      expect(duplicate.exitCode, 1);
      expect(duplicate.stderr, contains('Transport output already exists'));
      expect(
        File(p.join(output.path, 'pub-stage.json')).readAsBytesSync(),
        original['pub-stage.json'],
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'adjacent receipt replacement cannot replace caller-pinned archive bytes',
    () async {
      final written = await invoke('write', 'transport', [
        '--stage-evidence',
        stage.path,
      ]);
      expect(
        written.exitCode,
        0,
        reason: '${written.stdout}\n${written.stderr}',
      );
      final record = jsonDecode(written.stdout as String) as Map;
      final archive = File(
        p.join(fixture.root.path, 'transport', 'installation.tar'),
      );
      final changed = archive.readAsBytesSync()..[0] ^= 1;
      archive.writeAsBytesSync(changed);
      File(p.join(archive.parent.path, 'transport.json'))
          .writeAsStringSync('{"replacement":true}');
      final result = await invoke('read', 'refused', [
        '--archive',
        archive.path,
        '--expected-json',
        jsonEncode(record),
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('pinned identity'));
      expect(
        Directory(p.join(fixture.root.path, 'refused')).existsSync(),
        isFalse,
      );
    },
  );
}
