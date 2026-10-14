// Cold bootstrap: no package imports before the locked checkout is prepared.
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  Process? child;
  var completed = false;
  try {
    if (args.isNotEmpty) {
      throw ArgumentError('Usage: prepare_locked_checkout.dart');
    }
    child = await Process.start(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'pub',
      'get',
      '--enforce-lockfile',
    ], mode: ProcessStartMode.inheritStdio);
    final code = await child.exitCode.timeout(const Duration(seconds: 180));
    completed = true;
    if (code != 0) throw ProcessException('dart pub get', [], '', code);
  } catch (error) {
    stderr.writeln('Locked checkout preparation failed: $error');
    exitCode = 1;
  } finally {
    if (child != null && !completed) {
      child.kill(ProcessSignal.sigkill);
      try {
        await child.exitCode.timeout(const Duration(seconds: 5));
      } catch (error) {
        stderr.writeln('Unable to confirm pub preparation cleanup: $error');
        exitCode = 1;
      }
    }
  }
}
