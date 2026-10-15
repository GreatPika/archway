import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/native_process_support.dart';
import 'support/windows_job.dart';
import 'support/windows_process.dart';
import 'support/windows_process_pipes.dart';

void main() {
  test(
    'Windows missing process bridge fails with a preparation command',
    () async {
      final root = Directory.systemTemp.createTempSync('unprepared-process-');
      try {
        final source = File('test/support/windows_process.dart').absolute.uri;
        final child = File(p.join(root.path, 'unprepared.dart'))
          ..writeAsStringSync(
            "import '$source';\n"
            "void main() { WindowsSuspendedProcess.start([r'C:\\missing.exe']); }",
          );
        final result = await Process.run(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          child.path,
        ], workingDirectory: root.path).timeout(const Duration(seconds: 30));
        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          contains('Windows process test support is unprepared'),
        );
        expect(
          result.stderr,
          contains('tool/ci/prepare_windows_process_support.dart'),
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows ? 'Native Windows error capture control.' : false,
  );

  test(
    'Windows spawn error survives a later LastError overwrite',
    () async {
      final temp = Directory.systemTemp.createTempSync('spawn-error-control-');
      final absent = p.join(temp.path, 'missing.exe').toNativeUtf16();
      DynamicLibrary? library;
      try {
        final dll = File(p.join(temp.path, 'control.dll'));
        await buildNativeLibrary(
          File('test/support/windows_process_error_control.c').absolute,
          dll,
        );
        library = DynamicLibrary.open(dll.path);
        final capture = library
            .lookupFunction<
              Uint32 Function(Pointer<Utf16>),
              int Function(Pointer<Utf16>)
            >('archway_error_capture_control');
        expect(capture(absent), 2);
        expect(
          () =>
              WindowsSuspendedProcess.start([p.join(temp.path, 'missing.exe')]),
          throwsA(
            isA<OSError>()
                .having((error) => error.message, 'operation', 'CreateProcessW')
                .having((error) => error.errorCode, 'errorCode', 2),
          ),
        );
      } finally {
        library?.close();
        malloc.free(absent);
        temp.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows ? 'Native Windows error capture control.' : false,
  );

  test(
    'Windows pipe sinks preserve default buffering and allow no-buffer capture',
    () async {
      final temp = Directory.systemTemp.createTempSync('acceptance-pipes-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final script = File(p.join(temp.path, 'child.dart'))
        ..writeAsStringSync("""
import 'dart:io';
Future<void> main() async {
 stdout.add(List<int>.filled(100000, 97));
 stderr.add(List<int>.filled(70000, 98));
 await stdout.flush(); await stderr.flush();
}
""");
      for (final retain in [true, false]) {
        final output = <int>[], errors = <int>[];
        final pipes = retain
            ? WindowsProcessPipes(
                onStdout: output.addAll,
                onStderr: errors.addAll,
              )
            : WindowsProcessPipes(
                onStdout: output.addAll,
                onStderr: errors.addAll,
                retainOutput: false,
              );
        WindowsJob? job;
        WindowsSuspendedProcess? child;
        try {
          job = WindowsJob();
          child = job.spawn([
            Platform.resolvedExecutable,
            script.path,
          ], output: pipes);
          final result = await pipes.communicate(
            () => child!.exitCode,
            const Duration(seconds: 30),
          );
          expect(result.exitCode, 0);
          expect(output, List<int>.filled(100000, 97));
          expect(errors, List<int>.filled(70000, 98));
          expect(result.stdout, retain ? output : isEmpty);
          expect(result.stderr, retain ? errors : isEmpty);
        } finally {
          try {
            job?.close();
          } finally {
            try {
              child?.close();
            } finally {
              pipes.close();
            }
          }
        }
      }
    },
    skip: !Platform.isWindows ? 'Native Windows pipe control.' : false,
  );
}
