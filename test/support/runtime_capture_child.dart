// Real POSIX descendant-held stdout/stderr control for the runtime suite owner.
import 'dart:async';
import 'dart:io';

import '../runtime_process_smoke.dart' as runtime;

void publish(File file, String value) {
  final pending = File('${file.path}.pending')..writeAsStringSync(value);
  pending.renameSync(file.path);
}

Future<void> main(List<String> arguments) async {
  final marker = File(arguments[1]);
  if (arguments[0] == 'hold') {
    publish(marker, '$pid');
    await Future<void>.delayed(const Duration(seconds: 60));
  } else if (arguments[0] == 'parent') {
    await Process.start(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'run',
      Platform.script.toFilePath(),
      'hold',
      marker.path,
    ], mode: ProcessStartMode.inheritStdio);
    final elapsed = Stopwatch()..start();
    while (!marker.existsSync()) {
      if (elapsed.elapsed > const Duration(seconds: 5))
        throw StateError('Holder not ready');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    publish(File('${marker.path}.parent'), '$pid');
    stdout.write('out');
    stderr.write('err');
    await stdout.flush();
    await stderr.flush();
    exit(0);
  } else if (arguments[0] == 'capture') {
    try {
      await runtime.capture(
        [
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'run',
          Platform.script.toFilePath(),
          'parent',
          marker.path,
        ],
        cwd: Directory.current.path,
        environment: Platform.environment,
        timeout: const Duration(seconds: 5),
      );
      throw StateError('Held pipes unexpectedly reached EOF');
    } on TimeoutException {
      stdout.writeln('held-pipe timeout cleanup returned');
    }
  } else {
    throw ArgumentError('Unknown fixture role');
  }
}
