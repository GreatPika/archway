import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/preparation_process.dart';

void main() {
  test('stderr open failure closes the already opened stdout handle', () async {
    final root = Directory.systemTemp.createTempSync('preparation-open-');
    addTearDown(() => root.deleteSync(recursive: true));
    final log = File(p.join(root.path, 'preparation.log'));
    Directory('${log.path}.stderr').createSync();
    await expectLater(
      runPreparation(['must-not-launch'], Platform.environment, log),
      throwsA(isA<FileSystemException>()),
    );
    final leaked = Directory('/proc/self/fd')
        .listSync(followLinks: false)
        .whereType<Link>()
        .where((link) {
          try {
            return link.targetSync() == '${log.path}.stdout';
          } on FileSystemException {
            return false;
          }
        });
    expect(leaked, isEmpty);
  }, skip: Platform.isLinux ? false : 'Linux descriptor ownership observation');
  for (final timeoutCase in [false, true]) {
    test(
      '${timeoutCase ? 'timeout' : 'nonzero exit'} retains both preparation streams',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'preparation-capture-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final marker = File(p.join(root.path, 'ready'));
        final child = File(p.join(root.path, 'child.dart'))
          ..writeAsStringSync(r"""
import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.write('prepared-out'); stderr.write('prepared-err');
  await stdout.flush(); await stderr.flush();
  File(args[0]).writeAsStringSync('ready');
  if (args[1] == 'timeout') await Future<void>.delayed(const Duration(seconds: 30));
  exit(7);
}
""");
        final log = File(p.join(root.path, 'preparation.log'));
        final elapsed = Stopwatch()..start();
        final checked = expectLater(
          runPreparation(
            [
              Platform.resolvedExecutable,
              child.path,
              marker.path,
              timeoutCase ? 'timeout' : 'exit',
            ],
            Platform.environment,
            log,
            timeout: const Duration(seconds: 3),
          ),
          throwsA(
            timeoutCase
                ? isA<TimeoutException>()
                : isA<ProcessException>().having(
                    (e) => e.errorCode,
                    'exit code',
                    7,
                  ),
          ),
        );
        if (timeoutCase) {
          while (!marker.existsSync() &&
              elapsed.elapsed < const Duration(seconds: 2)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(marker.existsSync(), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(File('${log.path}.stdout').readAsStringSync(), 'prepared-out');
          expect(File('${log.path}.stderr').readAsStringSync(), 'prepared-err');
        }
        await checked;
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 10)));
        expect(log.readAsStringSync(), 'prepared-outprepared-err');
        expect(File('${log.path}.stdout').existsSync(), isFalse);
        expect(File('${log.path}.stderr').existsSync(), isFalse);
      },
    );
  }
}
