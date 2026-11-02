import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/native_acceptance.dart';

Directory canonicalTemporary(String prefix) => Directory(
  Directory.systemTemp.createTempSync(prefix).resolveSymbolicLinksSync(),
);

void main() {
  test(
    'installed capture preserves raw streams and an unexpected actual exit',
    () async {
      final base = canonicalTemporary('installed-capture-');
      addTearDown(() => base.deleteSync(recursive: true));
      final child = File(p.join(base.path, 'child.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() {stdout.add([255, 10]); stderr.write('fault'); exitCode = 17;}",
        );
      final recorder = InstalledCommandRecorder(
        output: base,
        timeout: const Duration(seconds: 30),
      );
      await expectLater(
        recorder.capture([Platform.resolvedExecutable, child.path]),
        throwsA(isA<SuiteExitFailure>()),
      );
      final record = recorder.commands.single;
      expect(record['exit'], 17);
      expect(record['stdout'], 'installed-0.stdout.log');
      expect(
        File(p.join(base.path, record['stdout'] as String)).readAsBytesSync(),
        [255, 10],
      );
      expect(record['stdout_sha256'], sha256.convert([255, 10]).toString());
      final accepted = await recorder.capture([
        Platform.resolvedExecutable,
        child.path,
      ], expectedExit: 17);
      expect(accepted.exitCode, 17);
      expect(accepted.stdout, [255, 10]);
      expect(accepted.stderr, utf8.encode('fault'));
    },
  );
  test(
    'installed timeout retains partial output and no invented exit',
    () async {
      final base = canonicalTemporary('installed-timeout-');
      addTearDown(() => base.deleteSync(recursive: true));
      final child = File(p.join(base.path, 'child.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; Future<void> main() async {stdout.write('before timeout'); await stdout.flush(); await Future<void>.delayed(const Duration(seconds: 30));}",
        );
      final recorder = InstalledCommandRecorder(
        output: base,
        timeout: const Duration(seconds: 2),
      );
      await expectLater(
        recorder.capture([Platform.resolvedExecutable, child.path]),
        throwsA(isA<TimeoutException>()),
      );
      expect(recorder.commands.single['exit'], isNull);
      expect(
        File(p.join(base.path, 'installed-0.stdout.log')).readAsStringSync(),
        'before timeout',
      );
      expect(
        jsonDecode(
          File(p.join(base.path, 'installed-0.json')).readAsStringSync(),
        )['timed_out'],
        true,
      );
    },
  );
  test(
    'aliased evidence is rejected after preserving the actual process receipt',
    () async {
      final base = canonicalTemporary('installed-alias-');
      addTearDown(() => base.deleteSync(recursive: true));
      final physical = Directory(p.join(base.path, 'physical'))..createSync();
      final alias = Link(p.join(base.path, 'alias'))..createSync(physical.path);
      final child = File(p.join(base.path, 'child.dart'))
        ..writeAsStringSync(
          "import 'dart:io'; void main() {stdout.write('captured');}",
        );
      final recorder = InstalledCommandRecorder(output: Directory(alias.path));
      await expectLater(
        recorder.capture([Platform.resolvedExecutable, child.path]),
        throwsA(isA<FormatException>()),
      );
      expect(recorder.commands.single['exit'], 0);
      expect(
        File(p.join(physical.path, 'installed-0.stdout.log'))
            .readAsStringSync(),
        'captured',
      );
      expect(
        recorder.commands.single['stdout_sha256'],
        sha256.convert(utf8.encode('captured')).toString(),
      );
      expect(
        jsonDecode(
          File(p.join(physical.path, 'installed-0.json')).readAsStringSync(),
        )['exit_code'],
        0,
      );
    },
  );
}
