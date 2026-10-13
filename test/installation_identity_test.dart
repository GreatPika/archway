import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

import '../tool/release/installation_identity.dart';
import 'support/process_lifecycle.dart';

void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('identity café-'));
  tearDown(() => base.deleteSync(recursive: true));

  test('source identity requires a clean tracked commit', () async {
    final repo = Directory(p.join(base.path, 'repository'))..createSync();
    Future<String> git(List<String> args) async {
      final result = await Process.run('git', ['-C', repo.path, ...args]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    await git(['init', '-q', '--template=']);
    for (final name in [
      'pubspec.lock',
      'assets/typescript/package-lock.json',
    ]) {
      File(p.join(repo.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('locked\n');
    }
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgSign=false',
      '-c',
      'maintenance.auto=false',
      'commit',
      '-qm',
      'fixture',
    ]);
    final identity = await sourceIdentity(repo);
    expect(identity, {
      'commit': await git(['rev-parse', 'HEAD']),
      'tree': await git(['rev-parse', 'HEAD^{tree}']),
      'lockfile_sha256': {
        'pubspec.lock':
            '3a52732e0c98263090a2cd2509e7d2244d7194bd65f78b29e6ef6448e8143666',
        'assets/typescript/package-lock.json':
            '3a52732e0c98263090a2cd2509e7d2244d7194bd65f78b29e6ef6448e8143666',
      },
    });
    final poison = p.join(base.path, 'missing-git-dir');
    await expectLater(
      sourceIdentity(
        repo,
        environment: {...Platform.environment, 'GIT_DIR': poison},
      ),
      throwsA(isA<ProcessException>()),
    );
    final child = File('test/support/installation_identity_child.dart')
        .absolute;
    final result = await Process.run(
      Platform.resolvedExecutable,
      [child.path, 'source-without-git-dir', repo.path],
      environment: {'GIT_DIR': poison},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(jsonDecode(result.stdout as String), identity);
    File(p.join(repo.path, 'untracked'))
        .writeAsStringSync('ignored by identity');
    expect(await sourceIdentity(repo), identity);
    File(p.join(repo.path, 'pubspec.lock')).writeAsStringSync('changed\n');
    await expectLater(sourceIdentity(repo), throwsStateError);
    await git(['add', 'pubspec.lock']);
    await expectLater(sourceIdentity(repo), throwsStateError);
  });

  test('runtime identity uses assembler cwd for relative PATH', () async {
    final caller = Directory(p.join(base.path, 'caller'));
    final repo = Directory(p.join(base.path, 'repository'));
    for (final (directory, identity) in [
      (caller, 'caller runtime'),
      (repo, 'build runtime'),
    ]) {
      final compiler = File(p.join(directory.path, 'compiler/runtime'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\nprintf "$identity\\n"\n');
      posix.chmod(compiler.path, '755');
    }
    final child = File('test/support/installation_identity_child.dart')
        .absolute;
    final result = await Process.run(
      Platform.resolvedExecutable,
      [child.path, 'runtime', repo.path],
      workingDirectory: caller.path,
      environment: {'PATH': 'compiler'},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, 'build runtime\n');
    expect(result.stderr, isEmpty);
  }, skip: Platform.isWindows ? 'Unix assembler PATH/cwd semantics' : false);

  test('runtime identity observes the actual runtime executable', () async {
    expect(
      await runtimeVersion(Platform.resolvedExecutable, base),
      startsWith('Dart SDK version: '),
    );
  });

  test('runtime identity combines streams and rejects nonzero exits', () async {
    final executable = File(p.join(base.path, 'runtime'))
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "output\\n"\nprintf "error\\n" >&2\n',
      );
    posix.chmod(executable.path, '755');
    expect(await runtimeVersion(executable.path, base), 'output\nerror');
    executable.writeAsStringSync(
      '#!/bin/sh\nprintf "failed\\n" >&2\nexit 17\n',
    );
    await expectLater(
      runtimeVersion(executable.path, base),
      throwsA(isA<ProcessException>().having((e) => e.errorCode, 'exit', 17)),
    );
  }, skip: Platform.isWindows ? 'POSIX runtime script fixture' : false);

  test(
    'runtime identity normalizes newlines in each stream before joining',
    () async {
      final executable = File(p.join(base.path, 'runtime'))
        ..writeAsStringSync(
          '#!/bin/sh\nprintf "  a\\r\\nb\\r\\n\\r\\nc\\r"\n'
          'printf "\\nd\\re\\r\\n  " >&2\n',
        );
      posix.chmod(executable.path, '755');
      expect(await runtimeVersion(executable.path, base), 'a\nb\n\nc\n\nd\ne');
    },
    skip: Platform.isWindows ? 'POSIX runtime script fixture' : false,
  );

  test(
    'runtime identity times out and reaps its direct child',
    () async {
      final pidFile = File(p.join(base.path, 'runtime.pid'));
      final executable = File(p.join(base.path, 'runtime'))
        ..writeAsStringSync(
          '#!/bin/sh\nprintf "\$\$" > runtime.pid\nexec /bin/sleep 120\n',
        );
      posix.chmod(executable.path, '755');
      await expectLater(
        runtimeVersion(executable.path, base),
        throwsA(isA<TimeoutException>()),
      );
      expect(isProcessAlive(int.parse(pidFile.readAsStringSync())), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: Platform.isWindows ? 'POSIX direct-child timeout fixture' : false,
  );
}
