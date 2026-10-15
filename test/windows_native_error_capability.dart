// Native Windows cold-error controls: every case runs in a fresh Dart process.
import 'dart:io';

import 'support/native_file_fixtures.dart';
import 'support/process_lifecycle.dart';
import 'support/windows_process.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  if (arguments.isEmpty) {
    for (final mode in [
      'missing-process',
      'missing-file',
      'missing-lock',
      'missing-executable',
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        Platform.script.toFilePath(),
        mode,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Cold $mode failed: \n${result.stderr}');
      }
      stdout.write(result.stdout);
    }
    return;
  }
  final root = Directory.systemTemp.createTempSync('archway-cold-error-');
  try {
    switch (arguments.single) {
      case 'missing-process':
        final child = await Process.run(Platform.resolvedExecutable, [
          '--version',
        ]);
        if (child.exitCode != 0)
          throw StateError('Child did not exit normally');
        if (isProcessAlive(child.pid))
          throw StateError('Exited child remains alive');
        terminateProcessId(child.pid);
      case 'missing-file':
        if (MalformedNativeFile(root.path, 'bad').existsExactly()) {
          throw StateError('Absent file exists');
        }
      case 'missing-lock':
        ExclusiveWindowsFileLock? lock;
        try {
          try {
            lock = ExclusiveWindowsFileLock('${root.path}\\missing');
            throw StateError('Absent output was opened');
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 2) rethrow;
          }
        } finally {
          lock?.close();
        }
      case 'missing-executable':
        WindowsSuspendedProcess? process;
        try {
          try {
            process = WindowsSuspendedProcess.start([
              '${root.path}\\missing.exe',
            ]);
            throw StateError('Missing executable started');
          } on OSError catch (error) {
            if (error.errorCode != 2) rethrow;
          }
        } finally {
          process?.close();
        }
      default:
        throw ArgumentError('Unknown cold error case');
    }
    stdout.writeln('Cold native error case passed: ${arguments.single}');
  } finally {
    root.deleteSync(recursive: true);
  }
}
