import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_assembly_init_probe.dart';
import 'support/native_process_support.dart';

void main() {
  test(
    'assembly controls cannot enlarge or disable the build budget',
    () async {
      for (final timeout in [Duration.zero, const Duration(seconds: 241)]) {
        await expectLater(
          assembleNativeInstallation(
            Directory.current,
            Directory.current,
            Directory.current,
            timeout: timeout,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'assembler timeout keeps actual partial stdout and stderr before cleanup',
    () async {
      final base = Directory(
        Directory.systemTemp
            .createTempSync('assembly-timeout-')
            .resolveSymbolicLinksSync(),
      );
      try {
        final source = Directory(p.join(base.path, 'fixture'))..createSync();
        final tool = Directory(p.join(source.path, 'tool'))..createSync();
        final output = p.join(base.path, 'not-built');
        File(
          p.join(
            tool.path,
            Platform.isWindows ? 'assemble_windows.ps1' : 'assemble.sh',
          ),
        ).writeAsStringSync(
          Platform.isWindows
              ? 'param([string]\$Output, [string]\$Dart)\n[Console]::Out.Write("partial café stdout"); [Console]::Out.Flush(); '
                    '[Console]::Error.Write("partial ü stderr"); [Console]::Error.Flush(); '
                    '[IO.File]::WriteAllText("\${Output}.ready", "ready"); while (\$true) {}\n'
              : "printf 'partial café stdout'; printf 'partial ü stderr' >&2; "
                    ': > "\$1.ready"; while :; do :; done\n',
        );
        final child = File('test/support/assembly_timeout_child.dart').absolute;
        final result = await runNativeProcess(
          [
            Platform.resolvedExecutable,
            child.path,
            source.path,
            output,
            base.path,
          ],
          timeout: const Duration(seconds: 20),
          workingDirectory: Directory.current.path,
        );
        final out = utf8.decode(result.stdout),
            err = utf8.decode(result.stderr);
        expect(result.exitCode, isNot(0), reason: '$out\n$err');
        expect(err, contains('TimeoutException'), reason: '$out\n$err');
        // This witness is written only after the fixture flushes both streams.
        // It distinguishes an absent/slow assembler prerequisite from output
        // lost by timeout capture, which must still fail the byte assertions.
        expect(
          File('$output.ready').existsSync(),
          isTrue,
          reason: 'Assembler never flushed its partial-output fixture.\n$err',
        );
        expect(out, contains('partial café stdout'));
        expect(err, contains('partial ü stderr'));
      } finally {
        base.deleteSync(recursive: true);
      }
    },
  );
}
