import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  if (!Platform.isLinux) return;

  test('unprivileged CLI child replaces its PID and preserves transport', () async {
    final root = Directory.systemTemp.createTempSync('archway-uid-child-');
    final cwd = Directory('${root.path}/other cwd café')..createSync();
    try {
      for (final directory in [root, cwd]) {
        expect(
          Process.runSync('/bin/chmod', ['755', directory.path]).exitCode,
          0,
        );
      }
      final child = await Process.start(
        Platform.resolvedExecutable,
        [
          File('test/support/linux_unprivileged_cli.dart').absolute.path,
          '/bin/sh',
          '-c',
          'printf "%s\\n" "\$\$" "\$PWD" "\$PATH" "\$1"; '
              'printf "fault\\n" >&2; exit 7',
          'fixture',
          'argument ü with spaces',
        ],
        workingDirectory: cwd.path,
        environment: {'PATH': '/no-runtime-here'},
      );
      await child.stdin.close();
      final output = child.stdout.transform(utf8.decoder).join();
      final errors = child.stderr.transform(utf8.decoder).join();
      try {
        expect(await child.exitCode.timeout(const Duration(seconds: 10)), 7);
        expect(
          await output,
          '${child.pid}\n${cwd.path}\n/no-runtime-here\nargument ü with spaces\n',
        );
        expect(await errors, 'fault\n');
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 2));
        await Future.wait([output, errors]).timeout(const Duration(seconds: 2));
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test(
    'unprivileged CLI child uses uid 65534 only for a root caller',
    () async {
      final libc = DynamicLibrary.process();
      final uid = libc.lookupFunction<Uint32 Function(), int Function()>(
        'getuid',
      )();
      final gid = libc.lookupFunction<Uint32 Function(), int Function()>(
        'getgid',
      )();
      for (final identity in [
        ('uid', '-u', uid == 0 ? 65534 : uid),
        ('gid', '-g', gid),
      ]) {
        final result = await _runPermissionChild(['/usr/bin/id', identity.$2]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, '${identity.$3}\n', reason: identity.$1);
        expect(result.stderr, isEmpty);
      }
    },
  );

  test('failed exec remains a visible child failure', () async {
    final result = await _runPermissionChild(['/no-executable-here/archway']);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('execv /no-executable-here/archway'));
    expect(result.stderr, contains('errno = 2'));
  });
}

Future<ProcessResult> _runPermissionChild(List<String> arguments) async {
  final child = await Process.start(Platform.resolvedExecutable, [
    'test/support/linux_unprivileged_cli.dart',
    ...arguments,
  ]);
  final completion = Future.wait<Object?>([
    child.exitCode,
    child.stdout.transform(utf8.decoder).join(),
    child.stderr.transform(utf8.decoder).join(),
    child.stdin.close(),
  ]);
  try {
    final result = await completion.timeout(const Duration(seconds: 10));
    return ProcessResult(child.pid, result[0] as int, result[1], result[2]);
  } finally {
    child.kill(ProcessSignal.sigkill);
    await completion.timeout(const Duration(seconds: 2));
  }
}
