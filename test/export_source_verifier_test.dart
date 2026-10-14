import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final verifier = p.absolute('tool/ci/verify_export_sources.dart');
  late Directory root;
  late String commit;
  const selected = [
    'pubspec.lock',
    'assets/typescript/helper.cjs',
    'assets/typescript/package-lock.json',
    'assets/typescript/README.md',
    'assets/typescript/licenses/café/license.txt',
  ];
  Future<String> git(List<String> args) async {
    final result = await Process.run('git', ['-C', root.path, ...args]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  Future<ProcessResult> invoke([String? expected]) => Process.run(
    Platform.resolvedExecutable,
    [verifier, expected ?? commit],
    workingDirectory: root.path,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('export source café ');
    await git(['init', '-q', '--template=']);
    await git(['config', 'core.autocrlf', 'true']);
    for (final name in [...selected, 'assets/typescript/ignored/nested.cjs']) {
      File(p.join(root.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('exact\nbytes\n');
    }
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      '-c',
      'commit.gpgSign=false',
      'commit',
      '-qm',
      'Fixture',
    ]);
    commit = await git(['rev-parse', 'HEAD']);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'checks exact Git bytes without package resolution, not Git status',
    () async {
      var result = await invoke();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains(commit));
      final helper = File(p.join(root.path, selected[1]));
      helper.deleteSync();
      await git(['checkout', '--', selected[1]]);
      expect(helper.readAsBytesSync(), 'exact\r\nbytes\r\n'.codeUnits);
      expect(await git(['status', '--porcelain']), isEmpty);
      result = await invoke();
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Export source bytes differ from Git: ${selected[1]}'),
      );
      helper.writeAsStringSync('exact\nbytes\n');
      result = await invoke('0' * 40);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Checkout commit differs'));
      expect(result.stderr, isNot(contains('Export source bytes differ')));
    },
  );

  test(
    'rejects changed copied source classes and excludes uncopied nested code',
    () async {
      for (final name in selected) {
        final file = File(p.join(root.path, name));
        file.writeAsStringSync('changed\n');
        final result = await invoke();
        expect(result.exitCode, isNot(0), reason: name);
        expect(
          result.stderr,
          contains('Export source bytes differ from Git: $name'),
        );
        file.writeAsStringSync('exact\nbytes\n');
      }
      File(p.join(root.path, 'assets/typescript/ignored/nested.cjs'))
          .writeAsStringSync('changed');
      final result = await invoke();
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
  );
}
