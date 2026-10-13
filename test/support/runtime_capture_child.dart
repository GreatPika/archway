// Real POSIX descendant-held stdout/stderr control for the process suite owners.
import 'dart:async';
import 'dart:io';

import '../alias_hop_recheck_process_smoke.dart' as alias;
import '../runtime_process_smoke.dart' as runtime;

void publish(File file, String value) {
  final pending = File('${file.path}.pending')..writeAsStringSync(value);
  pending.renameSync(file.path);
}

Future<void> main(List<String> arguments) async {
  if (arguments[0] == 'echo') {
    stdout.add([0, 255]);
    await stdout.addStream(stdin);
    stderr.add([255, 0, 10]);
    await stdout.flush();
    await stderr.flush();
    exitCode = 7;
    return;
  }
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
    final command = [
      Platform.resolvedExecutable,
      '--suppress-analytics',
      'run',
      Platform.script.toFilePath(),
      'parent',
      marker.path,
    ];
    final owner = arguments[2];
    try {
      if (owner == 'runtime') {
        await runtime.capture(
          command,
          cwd: Directory.current.path,
          environment: Platform.environment,
          timeout: const Duration(seconds: 5),
        );
      } else if (owner == 'alias') {
        await alias.capture(
          command.first,
          command.sublist(1),
          timeout: const Duration(seconds: 5),
        );
      } else {
        throw ArgumentError('Unknown capture owner');
      }
      throw StateError('Held pipes unexpectedly reached EOF');
    } on TimeoutException catch (error) {
      if (owner == 'alias' &&
          error.message !=
              '${command.sublist(1)} timed out; stdout=[111, 117, 116]; stderr=[101, 114, 114]') {
        stderr.writeln('Capture lost timeout diagnostics: $error');
        exitCode = 1;
        return;
      }
      stdout.writeln('held-pipe timeout cleanup returned');
    }
  } else {
    throw ArgumentError('Unknown fixture role');
  }
}
