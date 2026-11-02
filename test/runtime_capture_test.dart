import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/alias_capture.dart' as alias;
import 'support/process_lifecycle.dart';
import 'support/compiled_tool.dart';

void main() {
  late File captureKernel, entrypointKernel;
  setUpAll(() async {
    captureKernel = await prepareCompiledTool(
      'test/support/runtime_capture_child.dart',
    );
    if (Platform.isLinux) {
      entrypointKernel = await prepareCompiledTool(
        'test/support/runtime_entrypoint_child.dart',
      );
    }
  });
  test(
    'real entrypoint exits after flushed report with a pending native child',
    () async {
      Directory('build').createSync(recursive: true);
      final root = Directory('build')
          .createTempSync('entrypoint-pending-')
          .absolute;
      try {
        final result = await Process.run(Platform.resolvedExecutable, [
          entrypointKernel.path,
          root.path,
          Directory.current.absolute.path,
        ]);
        // Cleanup is checked before exit success so the regression's failure
        // cannot conceal a leaked pending fixture process.
        final marker = File('${root.path}/reaped');
        expect(marker.existsSync(), isTrue, reason: '${result.stderr}');
        expect(isProcessAlive(int.parse(marker.readAsStringSync())), isFalse);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          result.stdout,
          'entrypoint exit/schema verified; pending child killed and reaped\n',
        );
        expect(result.stderr, isEmpty);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: Platform.isLinux ? false : 'Linux child subreaper required to kill and reap the pending fixture child',
  );
  test('alias capture preserves stdin, raw output and nonzero exit', () async {
    final result = await alias.capture(Platform.resolvedExecutable, [
      captureKernel.path,
      'echo',
    ], input: 'stdin: λ\n');
    expect(result.code, 7);
    expect(result.out, [0, 255, 115, 116, 100, 105, 110, 58, 32, 206, 187, 10]);
    expect(result.err, [255, 0, 10]);
  });
  if (Platform.isWindows) return; // The held-pipe control requires POSIX.
  for (final owner in ['runtime', 'alias']) {
    test('$owner timeout disposes both pipes after the direct parent exits', () async {
      final root = Directory.systemTemp.createTempSync('runtime-held-pipe-');
      final marker = File('${root.path}/holder.pid');
      Process? process;
      var exited = false;
      Future<List<Object>>? result;
      try {
        process = await Process.start(Platform.resolvedExecutable, [
          captureKernel.path,
          'capture',
          marker.path,
          owner,
        ]);
        result = Future.wait<Object>([
          process.exitCode.then((code) {
            exited = true;
            return code;
          }),
          process.stdout.transform(utf8.decoder).join(),
          process.stderr.transform(utf8.decoder).join(),
        ], eagerError: true);
        result.ignore();
        final values = await result.timeout(const Duration(seconds: 15));
        expect(values, [0, 'held-pipe timeout cleanup returned\n', '']);
        expect(
          isProcessAlive(
            int.parse(File('${marker.path}.parent').readAsStringSync()),
          ),
          isFalse,
        );
        // The outer capture VM exited while this real descendant still held both
        // pipes; killing it first would conceal the original subscription leak.
        expect(isProcessAlive(int.parse(marker.readAsStringSync())), isTrue);
      } finally {
        try {
          if (marker.existsSync())
            terminateProcessId(int.parse(marker.readAsStringSync()));
        } finally {
          try {
            if (process != null && !exited) {
              process.kill(ProcessSignal.sigkill);
              await process.exitCode.timeout(const Duration(seconds: 5));
            }
            if (result != null)
              await result.timeout(const Duration(seconds: 5));
          } finally {
            root.deleteSync(recursive: true);
          }
        }
      }
    });
  }
}
