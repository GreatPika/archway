import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installer_command_recorder.dart';
import '../tool/ci/native_acceptance.dart';

void main() {
  test('retains installer records and exact original log names', () async {
    final output = Directory.systemTemp.createTempSync('installer-recorder-');
    addTearDown(() => output.deleteSync(recursive: true));
    for (final prefix in ['linux', 'macos']) {
      final recorder = InstallerCommandRecorder(
        output: output,
        prefix: prefix,
        timeout: Duration(seconds: prefix == 'linux' ? 180 : 240),
      );
      final args = ['/bin/sh', '-c', 'printf out; printf err >&2'];
      expect(await recorder.run(args), 'out');
      final record = recorder.commands.single;
      expect(record, {
        'arguments': args,
        'exit': 0,
        'stdout': '$prefix-0.stdout.log',
        'stderr': '$prefix-0.stderr.log',
        'stdout_sha256': sha256.convert(utf8.encode('out')).toString(),
        'stderr_sha256': sha256.convert(utf8.encode('err')).toString(),
      });
      expect(
        File(p.join(output.path, record['stdout'] as String))
            .readAsStringSync(),
        'out',
      );
      final proof = jsonDecode(
        File(p.join(output.path, '$prefix-0.json')).readAsStringSync(),
      );
      expect(proof['timeout_seconds'], prefix == 'linux' ? 180 : 240);
      args.add('mutation');
      expect(record['arguments'], hasLength(3));
      expect(
        () => (record['arguments'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(() => record.clear(), throwsUnsupportedError);
      expect(() => recorder.commands.clear(), throwsUnsupportedError);
    }
  }, skip: Platform.isWindows ? 'POSIX installer command capture.' : false);
  test(
    'records nonzero before throwing and accepts only exact expected exit',
    () async {
      final output = Directory.systemTemp.createTempSync('installer-exit-');
      addTearDown(() => output.deleteSync(recursive: true));
      final recorder = InstallerCommandRecorder(
        output: output,
        prefix: 'linux',
        timeout: const Duration(seconds: 180),
      );
      await expectLater(
        recorder.run(['/bin/sh', '-c', 'printf fault >&2; exit 7']),
        throwsA(isA<SuiteExitFailure>()),
      );
      expect(recorder.commands.single['exit'], 7);
      expect(
        await recorder.run([
          '/bin/sh',
          '-c',
          'printf absent; exit 1',
        ], expectedExit: 1),
        'absent',
      );
      await expectLater(
        recorder.run(['/bin/sh', '-c', 'exit 0'], expectedExit: 1),
        throwsA(isA<SuiteExitFailure>()),
      );
      expect(recorder.commands.map((value) => value['exit']), [7, 1, 0]);
      expect(recorder.commands.last['stdout'], 'linux-2.stdout.log');
    },
    skip: Platform.isWindows ? 'POSIX installer command capture.' : false,
  );

  test('timeout retains live partial streams without invented exit', () async {
    final output = Directory.systemTemp.createTempSync('installer-timeout-');
    addTearDown(() => output.deleteSync(recursive: true));
    final recorder = InstallerCommandRecorder(
      output: output,
      prefix: 'macos',
      timeout: const Duration(milliseconds: 500),
    );
    final checked = expectLater(
      recorder.run([
        '/bin/sh',
        '-c',
        'printf partial; printf fault >&2; exec sleep 30',
      ]),
      throwsA(isA<TimeoutException>()),
    );
    final log = File(p.join(output.path, 'macos-0.stdout.log'));
    final waited = Stopwatch()..start();
    while ((!log.existsSync() || log.lengthSync() == 0) &&
        waited.elapsed < const Duration(milliseconds: 400)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(log.readAsStringSync(), 'partial');
    expect(
      recorder.commands,
      isEmpty,
      reason: 'Output is durable before completion',
    );
    await checked;
    final record = recorder.commands.single;
    expect(record['exit'], isNull);
    expect(
      record['stdout_sha256'],
      sha256.convert(utf8.encode('partial')).toString(),
    );
    expect(
      record['stderr_sha256'],
      sha256.convert(utf8.encode('fault')).toString(),
    );
    final proof = jsonDecode(
      File(p.join(output.path, 'macos-0.json')).readAsStringSync(),
    );
    expect(proof['timed_out'], true);
    expect(proof['exit_code'], isNull);
    expect(proof['timeout_seconds'], 0.5);
  }, skip: Platform.isWindows ? 'POSIX installer command capture.' : false);

  test(
    'spawn failure retains proof and exclusive evidence never becomes history',
    () async {
      final output = Directory.systemTemp.createTempSync('installer-spawn-');
      addTearDown(() => output.deleteSync(recursive: true));
      final recorder = InstallerCommandRecorder(
        output: output,
        prefix: 'linux',
        timeout: const Duration(seconds: 180),
      );
      await expectLater(
        recorder.run([p.join(output.path, 'absent')]),
        throwsA(isA<ProcessException>()),
      );
      expect(recorder.commands.single['exit'], isNull);
      final proof = jsonDecode(
        File(p.join(output.path, 'linux-0.json')).readAsStringSync(),
      );
      expect(proof['timed_out'], false);
      expect(proof['exit_code'], isNull);
      for (final suffix in ['stdout.log', 'stderr.log', 'json']) {
        final folder = Directory(p.join(output.path, suffix))..createSync();
        final prior = File(p.join(folder.path, 'macos-0.$suffix'))
          ..writeAsStringSync('original');
        final blocked = InstallerCommandRecorder(
          output: folder,
          prefix: 'macos',
          timeout: const Duration(seconds: 240),
        );
        await expectLater(
          blocked.run([
            '/bin/sh',
            '-c',
            'touch launched',
          ], workingDirectory: folder.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(blocked.commands, isEmpty);
        expect(prior.readAsStringSync(), 'original');
        expect(File(p.join(folder.path, 'launched')).existsSync(), false);
      }
    },
    skip: Platform.isWindows ? 'POSIX installer command capture.' : false,
  );

  test('recorder rejects unsupported hosts and invalid configuration', () {
    InstallerCommandRecorder make(String prefix, Duration timeout) =>
        InstallerCommandRecorder(
          output: Directory.systemTemp,
          prefix: prefix,
          timeout: timeout,
        );
    if (Platform.isWindows) {
      expect(
        () => make('linux', const Duration(seconds: 180)),
        throwsUnsupportedError,
      );
      expect(
        () => make('macos', const Duration(seconds: 240)),
        throwsUnsupportedError,
      );
    } else {
      expect(
        () => make('windows', const Duration(seconds: 180)),
        throwsArgumentError,
      );
      expect(() => make('linux', Duration.zero), throwsArgumentError);
      expect(
        () => make('macos', const Duration(seconds: -1)),
        throwsArgumentError,
      );
    }
  });
}
