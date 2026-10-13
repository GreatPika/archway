import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'alias_hop_recheck_process_smoke.dart' as alias;
import 'support/process_lifecycle.dart';

void main() {
  test('alias capture preserves stdin, raw output and nonzero exit', () async {
    final result = await alias.capture(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'run',
      'test/support/runtime_capture_child.dart',
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
          '--suppress-analytics',
          'run',
          'test/support/runtime_capture_child.dart',
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
