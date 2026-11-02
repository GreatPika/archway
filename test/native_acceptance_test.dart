import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_acceptance.dart';
import '../tool/ci/native_acceptance_capture.dart';

void main() {
  test(
    'proof observer runs after durable receipt before original exit failure',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'acceptance-observer-',
      );
      addTearDown(() => output.deleteSync(recursive: true));
      final child = File(p.join(output.path, 'child.dart'))
        ..writeAsStringSync("import 'dart:io'; void main() { exit(7); }");
      Map<String, Object?>? observed;
      await expectLater(
        executeSuite(
          'observed',
          [Platform.resolvedExecutable, child.path],
          Directory.current.path,
          Platform.environment,
          output,
          onProof: (proof) {
            expect(
              jsonDecode(
                File(p.join(output.path, 'observed.json')).readAsStringSync(),
              ),
              proof,
            );
            observed = proof;
          },
        ),
        throwsA(
          isA<SuiteExitFailure>().having(
            (error) => identical(error.proof, observed),
            'original proof',
            true,
          ),
        ),
      );
      expect(observed?['exit_code'], 7);
      observed = null;
      await expectLater(
        executeSuite(
          'observed',
          [child.path],
          Directory.current.path,
          Platform.environment,
          output,
          onProof: (proof) {
            observed = proof;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        observed,
        isNull,
        reason: 'Prior evidence is never observed as new proof',
      );
    },
  );
  test(
    'explicit aggregate budget is retained in the original receipt',
    () async {
      final temp = Directory.systemTemp.createTempSync('acceptance-budget-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'child.dart'))
        ..writeAsStringSync('void main() {}');
      final proof = await executeSuite(
        'source-tests',
        [Platform.resolvedExecutable, script.path],
        Directory.current.path,
        Platform.environment,
        temp,
        timeout: const Duration(seconds: 900),
      );
      expect(proof['timeout_seconds'], 900);
      expect(proof['exit_code'], 0);
      expect(proof['timed_out'], false);
      expect(
        jsonDecode(
          File(p.join(temp.path, 'source-tests.json')).readAsStringSync(),
        ),
        proof,
      );
    },
  );
  test(
    'capture write failure propagates without waiting for child completion',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'acceptance-write-failure-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'child.dart'))
        ..writeAsStringSync("""
import 'dart:io';
Future<void> main() async {
 stdout.write('trigger'); await stdout.flush();
 await Future<void>.delayed(const Duration(seconds: 30));
}
""");
      final out = (File(p.join(temp.path, 'out'))..createSync()).openSync();
      final err = (File(
        p.join(temp.path, 'err'),
      )..createSync()).openSync(mode: FileMode.writeOnly);
      final elapsed = Stopwatch()..start();
      try {
        await expectLater(
          captureAcceptanceProcess(
            [Platform.resolvedExecutable, script.path],
            Directory.current.path,
            Platform.environment,
            out,
            err,
            suiteTimeout,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 10)));
      } finally {
        out.closeSync();
        err.closeSync();
      }
    },
  );
  test(
    'each preexisting evidence name prevents launch without overwriting it',
    () async {
      for (final suffix in ['stdout.log', 'stderr.log', 'json']) {
        final temp = Directory.systemTemp.createTempSync(
          'acceptance-exclusive-',
        );
        addTearDown(() => temp.deleteSync(recursive: true));
        final evidence = File(p.join(temp.path, 'example.$suffix'))
          ..writeAsStringSync('prior evidence');
        await expectLater(
          executeSuite(
            'example',
            [p.join(temp.path, 'absent')],
            Directory.current.path,
            Platform.environment,
            temp,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(evidence.readAsStringSync(), 'prior evidence');
      }
    },
  );
  test(
    'nonzero and timeout retain logs, receipt, and bounded child cleanup',
    () async {
      for (final timeoutCase in [false, true]) {
        final temp = Directory.systemTemp.createTempSync('acceptance-failure-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final marker = File(p.join(temp.path, 'ready'));
        final script = File(p.join(temp.path, 'child.dart'))
          ..writeAsStringSync("""
import 'dart:io';
Future<void> main(List<String> args) async {
 stdout.write('partial'); stderr.write('fault');
 await stdout.flush(); await stderr.flush();
 File(args[0]).writeAsStringSync('\$pid');
 if (args[1] == 'timeout') await Future<void>.delayed(const Duration(seconds: 30));
 exit(7);
}
""");
        final run = executeSuite(
          'failure',
          [
            Platform.resolvedExecutable,
            script.path,
            marker.path,
            timeoutCase ? 'timeout' : 'exit',
          ],
          Directory.current.path,
          Platform.environment,
          temp,
          timeout: timeoutCase ? const Duration(seconds: 3) : suiteTimeout,
        );
        // Attach error observation before waiting on durable output.
        final checked = expectLater(
          run,
          throwsA(
            timeoutCase ? isA<TimeoutException>() : isA<SuiteExitFailure>(),
          ),
        );
        final waited = Stopwatch()..start();
        while (!marker.existsSync() &&
            waited.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(marker.existsSync(), true);
        // The running child has flushed: evidence must already be on disk.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          File(p.join(temp.path, 'failure.stdout.log')).readAsStringSync(),
          'partial',
        );
        await checked;
        final proof = jsonDecode(
          File(p.join(temp.path, 'failure.json')).readAsStringSync(),
        );
        expect(proof['timed_out'], timeoutCase);
        expect(proof['exit_code'], timeoutCase ? null : 7);
        expect(
          File(p.join(temp.path, 'failure.stderr.log')).readAsStringSync(),
          'fault',
        );
        expect(
          proof['stderr_sha256'],
          sha256.convert(utf8.encode('fault')).toString(),
        );
        expect(proof['elapsed_seconds'], lessThan(10));
        if (timeoutCase && !Platform.isWindows) {
          expect(
            Process.killPid(
              int.parse(marker.readAsStringSync()),
              ProcessSignal.sigterm,
            ),
            false,
            reason: 'The owned direct child must already be reaped',
          );
        }
      }
    },
  );
  test(
    'spawn rejection records failure evidence without a success receipt',
    () async {
      final temp = Directory.systemTemp.createTempSync('acceptance-rejected-');
      addTearDown(() => temp.deleteSync(recursive: true));
      await expectLater(
        executeSuite(
          'missing',
          [p.join(temp.path, 'absent')],
          Directory.current.path,
          Platform.environment,
          temp,
        ),
        throwsA(anyOf(isA<ProcessException>(), isA<OSError>())),
      );
      final proof = jsonDecode(
        File(p.join(temp.path, 'missing.json')).readAsStringSync(),
      );
      expect(proof['exit_code'], isNull);
      expect(proof['timed_out'], false);
    },
  );
  test(
    'suite capture writes exact durable receipt and never overwrites evidence',
    () async {
      final temp = Directory.systemTemp.createTempSync('acceptance-capture-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'child.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() { stdout.add([0, 255, 10]); stderr.write('error'); }",
        );
      final command = [Platform.resolvedExecutable, script.path];
      final proof = await executeSuite(
        'example',
        command,
        Directory.current.path,
        Platform.environment,
        temp,
      );
      expect(proof.keys.toSet(), {
        'suite',
        'command',
        'exit_code',
        'timed_out',
        'elapsed_seconds',
        'timeout_seconds',
        'stdout',
        'stderr',
        'stdout_sha256',
        'stderr_sha256',
      });
      expect(proof['exit_code'], 0);
      expect(proof['timed_out'], false);
      expect(proof['timeout_seconds'], 600);
      expect(proof['command'], command);
      expect(File(p.join(temp.path, 'example.stdout.log')).readAsBytesSync(), [
        0,
        255,
        10,
      ]);
      expect(proof['stdout_sha256'], sha256.convert([0, 255, 10]).toString());
      expect(
        jsonDecode(File(p.join(temp.path, 'example.json')).readAsStringSync()),
        proof,
      );
      await expectLater(
        executeSuite(
          'example',
          command,
          Directory.current.path,
          Platform.environment,
          temp,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(temp.path, 'example.stdout.log')).readAsBytesSync(), [
        0,
        255,
        10,
      ]);
    },
  );
}
