import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/pub_stage_fixture.dart';

void main() {
  test(
    'SDK export requires an explicit registry-ready stage before execution',
    () async {
      final fixture = await preparePubStageFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final stage = p.join(fixture.root.path, 'private');
      final prepared = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/pub/stage.dart',
        '--source',
        fixture.source.path,
        '--descriptor',
        fixture.descriptor.path,
        '--expected-commit',
        fixture.identity['commit'] as String,
        '--output',
        stage,
      ]);
      expect(
        prepared.exitCode,
        0,
        reason: '${prepared.stdout}\n${prepared.stderr}',
      );
      final output = p.join(fixture.root.path, 'export');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/pub/export.dart',
        '--source',
        fixture.source.path,
        '--stage',
        stage,
        '--expected-commit',
        fixture.identity['commit'] as String,
        '--evidence',
        p.join(fixture.root.path, 'evidence'),
        '--pub-cache',
        fixture.root.path,
        '--output',
        output,
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('identity or intent differs'));
      expect(Directory(output).existsSync(), isFalse);
    },
  );
}
