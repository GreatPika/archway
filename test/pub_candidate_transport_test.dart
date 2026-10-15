import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/compiled_tool.dart';
import 'support/pub_candidate_fixture.dart';

void main() {
  late File tool;
  setUpAll(() async {
    tool = await prepareCompiledTool('tool/ci/pub_stage_transport.dart');
  });
  test('candidate transport preserves SDK bytes and requires explicit receive intent', () async {
    final prepared = await preparePubCandidateFixture();
    final fixture = prepared.fixture;
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    Future<ProcessResult> invoke(
      String operation,
      String output,
      List<String> options,
    ) => Process.run(Platform.resolvedExecutable, [
      tool.path,
      operation,
      '--source',
      fixture.source.path,
      '--expected-source',
      fixture.identity['commit'] as String,
      '--run-id',
      '123',
      '--run-attempt',
      '2',
      '--output',
      p.join(fixture.root.path, output),
      ...options,
    ]);
    final upload = File(p.join(prepared.candidate.path, 'pub-package.tar.gz'))
        .readAsBytesSync();
    final original = File(
      p.join(prepared.candidate.path, 'execution/installed-1.json'),
    );
    final saved = original.readAsStringSync();
    final changed = jsonDecode(saved) as Map<String, dynamic>;
    changed['exit_code'] = 0;
    original.writeAsStringSync(jsonEncode(changed));
    final badStatus = await invoke('write', 'bad-status', [
      '--stage-evidence',
      prepared.candidate.path,
      '--registry-ready',
    ]);
    expect(badStatus.exitCode, 1);
    expect(
      badStatus.stderr,
      contains('Execution failed, timed out, or command differs'),
    );
    expect(
      Directory(p.join(fixture.root.path, 'bad-status')).existsSync(),
      isFalse,
    );
    original.writeAsStringSync(saved);
    final damaged = List<int>.from(upload);
    damaged[damaged.length ~/ 2] ^= 1;
    final archive = File(p.join(prepared.candidate.path, 'pub-package.tar.gz'));
    archive.writeAsBytesSync(damaged);
    final badUpload = await invoke('write', 'bad-upload', [
      '--stage-evidence',
      prepared.candidate.path,
      '--registry-ready',
    ]);
    expect(badUpload.exitCode, 1);
    expect(
      badUpload.stderr,
      contains('Archive input differs from pinned identity'),
    );
    expect(
      Directory(p.join(fixture.root.path, 'bad-upload')).existsSync(),
      isFalse,
    );
    archive.writeAsBytesSync(upload);
    final written = await invoke('write', 'transport', [
      '--stage-evidence',
      prepared.candidate.path,
      '--registry-ready',
    ]);
    expect(written.exitCode, 0, reason: '${written.stdout}\n${written.stderr}');
    final record = jsonDecode(written.stdout as String) as Map;
    expect(record['schema_version'], 2);
    expect((record['files'] as Map).keys.toSet(), {
      'pub-stage.json',
      'report.json',
      'pub-package.tar.gz',
      for (var i = 0; i < 3; i++) ...[
        'execution/installed-$i.json',
        'execution/installed-$i.stdout.log',
        'execution/installed-$i.stderr.log',
      ],
    });
    final options = [
      '--archive',
      p.join(fixture.root.path, 'transport', 'installation.tar'),
      '--expected-json',
      jsonEncode(record),
    ];
    final refused = await invoke('read', 'received', options);
    expect(refused.exitCode, 1);
    expect(refused.stderr, contains('explicit registry intent'));
    expect(
      Directory(p.join(fixture.root.path, 'received')).existsSync(),
      isFalse,
    );
    final received = await invoke('read', 'received', [
      ...options,
      '--registry-ready',
    ]);
    expect(
      received.exitCode,
      0,
      reason: '${received.stdout}\n${received.stderr}',
    );
    expect(
      File(p.join(fixture.root.path, 'received/pub-package.tar.gz'))
          .readAsBytesSync(),
      upload,
    );
    final package = Directory(p.join(prepared.stage.path, 'package'));
    for (final file in package.listSync(recursive: true).whereType<File>()) {
      expect(
        File(
          p.join(
            fixture.root.path,
            'received/package',
            p.relative(file.path, from: package.path),
          ),
        ).readAsBytesSync(),
        file.readAsBytesSync(),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
