import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/process_lifecycle.dart';

void main() {
  if (Platform.isWindows) return; // This regression is in the POSIX owner only.
  test('runtime timeout disposes both pipes after the direct parent exits', () async {
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
          if (result != null) await result.timeout(const Duration(seconds: 5));
        } finally {
          root.deleteSync(recursive: true);
        }
      }
    }
  });
}
