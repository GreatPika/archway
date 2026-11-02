import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import '../tool/installation_lifecycle.dart';

void main() {
  test('missing Git fails and cleans the owned lifecycle fixture', () async {
    final temporary = Directory.systemTemp.createTempSync('archway-no-git-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final root = temporary.resolveSymbolicLinksSync();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('tool/installation_lifecycle.dart').absolute.path,
      ],
      environment: {
        for (final entry in Platform.environment.entries)
          if (!{
            'PATH',
            'TMP',
            'TEMP',
            'TMPDIR',
          }.contains(entry.key.toUpperCase()))
            entry.key: entry.value,
        'PATH': root,
        'TMP': root,
        'TEMP': root,
        'TMPDIR': root,
      },
      includeParentEnvironment: false,
    );
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Git executable is not available'));
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'Git PATH lookup returns an absolute native executable without a shell',
    () {
      final root = Directory.systemTemp.createTempSync('archway-git-lookup-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File(
        p.join(root.path, Platform.isWindows ? 'git.exe' : 'git'),
      )..writeAsStringSync('fixture');
      expect(
        findGitExecutable({'Path': root.path}),
        file.resolveSymbolicLinksSync(),
      );
      expect(p.isAbsolute(findGitExecutable({'PATH': root.path})), isTrue);
      expect(
        () => findGitExecutable({'PATH': p.join(root.path, 'missing')}),
        throwsStateError,
      );
    },
  );
  test(
    'predecessor edits exactly one version marker, preserving all other bytes',
    () {
      const original = 'name: archway\nversion: 0.1.0\nother: untouched\n';
      final marker = RegExp(r'^version: [^\r\n]+$', multiLine: true);
      expect(
        replaceVersionMarker(original, marker, 'version: $predecessorVersion'),
        'name: archway\nversion: 0.0.0-test\nother: untouched\n',
      );
      expect(
        () => replaceVersionMarker('name: only\n', marker, ''),
        throwsStateError,
      );
      expect(
        () => replaceVersionMarker('$original$original', marker, ''),
        throwsStateError,
      );
    },
  );
  test('version evidence requires exact output, success, and empty stderr', () {
    void check(String output, {int exit = 0, String error = ''}) =>
        verifyVersionOutput((
          exitCode: exit,
          stdout: utf8.encode(output),
          stderr: utf8.encode(error),
        ), '0.1.0');
    check('archway 0.1.0\n');
    check('archway 0.1.0\r\n');
    for (final output in [
      'archway 0.0.0-test\n',
      'archway 0.1.0',
      'archway 0.1.0\nextra\n',
    ]) {
      expect(() => check(output), throwsStateError);
    }
    expect(() => check('archway 0.1.0\n', exit: 1), throwsStateError);
    expect(() => check('archway 0.1.0\n', error: 'warning'), throwsStateError);
  });
}
