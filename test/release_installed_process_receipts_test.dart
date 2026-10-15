import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/release_installed_process_receipts.dart';

void main() {
  late Directory root, logs;
  late List<dynamic> rows;
  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('installed-original-')
          .resolveSymbolicLinksSync(),
    );
    logs = Directory(p.join(root.path, 'logs'))..createSync();
    final child = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync(
        "import 'dart:io';void main(List<String> args){stdout.writeln(args.single);stderr.writeln('separate stderr');exitCode=37;}",
      );
    final recorder = InstalledCommandRecorder(output: logs);
    await recorder.capture([
      Platform.resolvedExecutable,
      child.path,
      'literal café &',
    ], expectedExit: 37);
    rows = jsonDecode(jsonEncode(recorder.commands)) as List;
  });
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'reader binds exact original nonzero command and both stream identities',
    () {
      final proof = validateInstalledProcessReceipts(
        rows,
        logs,
        timeoutSeconds: {30},
      ).single;
      expect(proof.exitCode, 37);
      expect(proof.arguments.last, 'literal café &');
      expect(utf8.decode(proof.stdout), 'literal café &\n');
      expect(utf8.decode(proof.stderr), 'separate stderr\n');
      expect(
        () => validateInstalledProcessReceipts(
          rows,
          logs,
          timeoutSeconds: {30, 120},
          timeoutFor: (_, __) => 120,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'caller-selected budget',
            'Installed original configured timeout differs',
          ),
        ),
      );

      rows.single['arguments'][2] = 'changed argv';
      expect(
        () =>
            validateInstalledProcessReceipts(rows, logs, timeoutSeconds: {30}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('original'),
          ),
        ),
      );
    },
  );
  test('reader rejects failed original execution and altered original stream bytes', () {
    final file = File(p.join(logs.path, 'installed-0.json'));
    final original = file.readAsStringSync();
    final changed = jsonDecode(original) as Map;
    changed['timed_out'] = true;
    file.writeAsStringSync(jsonEncode(changed));
    expect(
      () => validateInstalledProcessReceipts(rows, logs, timeoutSeconds: {30}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('timed out'),
        ),
      ),
    );
    file.writeAsStringSync(original);
    expect(
      () => validateInstalledProcessReceipts(rows, logs, timeoutSeconds: {120}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('timeout'),
        ),
      ),
    );
    File(p.join(logs.path, 'installed-0.stdout.log'))
        .writeAsStringSync('altered bytes');
    expect(
      () => validateInstalledProcessReceipts(rows, logs, timeoutSeconds: {30}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('hash differs'),
        ),
      ),
    );
  });
  test(
    'matching Windows receipt metadata retains producer representation limits',
    () {
      final file = File(p.join(logs.path, 'installed-0.json'));
      final original = jsonDecode(file.readAsStringSync()) as Map;
      void metadata(String application, String command) {
        final representation = {
          'application_name': application,
          'command_line': command,
          'logical_arguments': rows.single['arguments'],
        };
        rows.single['windows_execution'] = representation;
        original['windows_execution'] = representation;
        file.writeAsStringSync(jsonEncode(original));
      }

      void admit() =>
          validateInstalledProcessReceipts(rows, logs, timeoutSeconds: {30});
      // Structural Windows metadata fixture only; the original child ran on this host.
      metadata(r'C:\Windows\System32\cmd.exe', 'valid explicit command');
      admit();
      for (final (application, command) in [
        ('C:\\Windows\\cmd.exe\u0000', 'valid explicit command'),
        (r'C:\Windows\System32\cmd.exe', 'x' * 32767),
      ]) {
        metadata(application, command);
        expect(
          admit,
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'representation boundary',
              'Installed Windows execution identity differs',
            ),
          ),
        );
      }
    },
  );
}
