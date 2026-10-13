import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/aot_init_assertions.dart';

void main() {
  late Directory base;
  setUp(() {
    base = Directory(
      Directory.systemTemp
          .createTempSync('aot-oracle-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => base.deleteSync(recursive: true));

  test(
    'shared init oracle accepts actual source process through explicit adapter',
    () async {
      final binary = File(p.join(Directory.current.path, 'bin/archway.dart'));
      final result = await assertAotInit(
        binary,
        base,
        command: (arguments) => [Platform.resolvedExecutable, ...arguments],
        label: 'source control',
      );
      expect(result.exitCode, 0);
    },
  );
  test('independent controlled response satisfies the oracle', () async {
    final child = File(
      p.join(Directory.current.path, 'test/support/aot_init_oracle_child.dart'),
    );
    final result = await assertAotInit(
      File('unused'),
      base,
      command: (args) => [
        Platform.resolvedExecutable,
        child.path,
        'valid',
        ...args,
      ],
      label: 'controlled response',
    );
    expect(result.exitCode, 0);
  });
  test('guide text retains universal-newline reading without relaxing policy bytes', () async {
    final child = File(
      p.join(Directory.current.path, 'test/support/aot_init_oracle_child.dart'),
    );
    final result = await assertAotInit(
      File('unused'),
      base,
      command: (args) => [
        Platform.resolvedExecutable,
        child.path,
        'guide-crlf',
        ...args,
      ],
      label: 'CRLF guide control',
    );
    expect(result.exitCode, 0);
  });
  for (final mode in [
    'exit',
    'stderr',
    'envelope',
    'payload',
    'files',
    'policy',
    'guide',
    'cwd',
    'bom',
    'utf8',
    'multiline',
    'no-lf',
  ]) {
    test('shared oracle rejects $mode process corruption', () async {
      final child = File(
        p.join(
          Directory.current.path,
          'test/support/aot_init_oracle_child.dart',
        ),
      );
      await expectLater(
        assertAotInit(
          File('unused'),
          base,
          command: (args) => [
            Platform.resolvedExecutable,
            child.path,
            mode,
            ...args,
          ],
          label: 'negative control',
        ),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
    });
  }
}
