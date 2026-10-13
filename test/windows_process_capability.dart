// Explicit native-Windows capability probe. Other hosts cannot certify it.
import 'dart:convert';
import 'dart:io';

import 'support/process_lifecycle.dart';
import 'support/windows_process.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  final root = Directory.systemTemp.createTempSync('archway-suspended-');
  final marker = File('${root.path}\\ready.json');
  final child = File('test/support/process_fixture_child.dart').absolute.path;
  final payload = ['', 'two words', 'a"b', r'C:\trailing space\', 'café'];
  final arguments = [
    Platform.resolvedExecutable,
    '--suppress-analytics',
    'run',
    child,
    marker.path,
    ...payload,
  ];
  WindowsSuspendedProcess? process;
  try {
    process = WindowsSuspendedProcess.start(
      arguments,
      workingDirectory: root.path,
      environment: {
        ...Platform.environment,
        'ARCHWAY_FIXTURE_VALUE': 'native café',
      },
    );
    check(isProcessAlive(process.pid), 'Suspended process must be alive');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    check(
      !marker.existsSync(),
      'Child ran before explicit initial-thread resume',
    );
    process.resume();
    final deadline = Stopwatch()..start();
    while (!marker.existsSync() &&
        deadline.elapsed < const Duration(seconds: 10)) {
      if (process.exitCode != null)
        throw StateError('Child exited before readiness');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    check(marker.existsSync(), 'Resumed child did not write readiness marker');
    final value = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
    check(
      jsonEncode(value['arguments']) == jsonEncode(payload),
      'Native argv did not roundtrip',
    );
    check(value['directory'] == root.path, 'Native cwd not applied');
    check(
      value['environment'] == 'native café',
      'Native environment not applied',
    );
    process.close();
    check(process.exitCode == 1, 'Close did not confirm process termination');
    check(!isProcessAlive(process.pid), 'Closed fixture process remains alive');
    process.close();
    marker.deleteSync();
    process = WindowsSuspendedProcess.start(arguments);
    process.close();
    check(process.exitCode == 1, 'Suspended cleanup not confirmed');
    check(
      !marker.existsSync(),
      'Closing suspended process executed child code',
    );
    var rejected = false;
    try {
      WindowsSuspendedProcess.start(['${root.path}\\missing.exe']);
    } on OSError {
      rejected = true;
    }
    check(rejected, 'Missing executable was not rejected');
    stdout.writeln('Windows suspended process capability passed');
  } finally {
    process?.close();
    root.deleteSync(recursive: true);
  }
}
