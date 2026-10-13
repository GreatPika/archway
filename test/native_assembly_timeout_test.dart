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
        File(
          p.join(
            tool.path,
            Platform.isWindows ? 'assemble_windows.ps1' : 'assemble.sh',
          ),
        ).writeAsStringSync(
          Platform.isWindows
              ? 'param([string]\$Output, [string]\$Dart)\n[Console]::Out.Write("partial café stdout"); [Console]::Out.Flush(); '
                    '[Console]::Error.Write("partial ü stderr"); [Console]::Error.Flush(); while (\$true) {}\n'
              : "printf 'partial café stdout'; printf 'partial ü stderr' >&2; while :; do :; done\n",
        );
        final child = File('test/support/assembly_timeout_child.dart').absolute;
        final result = await runNativeProcess(
          [
            Platform.resolvedExecutable,
            child.path,
            source.path,
            p.join(base.path, 'not-built'),
            base.path,
          ],
          timeout: const Duration(seconds: 20),
          workingDirectory: Directory.current.path,
        );
        expect(result.exitCode, isNot(0));
        expect(utf8.decode(result.stdout), contains('partial café stdout'));
        expect(utf8.decode(result.stderr), contains('partial ü stderr'));
        expect(utf8.decode(result.stderr), contains('TimeoutException'));
        expect(Directory(p.join(base.path, 'not-built')).existsSync(), false);
      } finally {
        base.deleteSync(recursive: true);
      }
    },
  );
}
