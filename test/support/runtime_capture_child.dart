// Real POSIX descendant-held stdout/stderr control for the process suite owners.
import 'dart:async';
import 'dart:io';

import '../alias_hop_recheck_process_smoke.dart' as alias;
import '../runtime_process_smoke.dart' as runtime;

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
  if (arguments[0] == 'capture') {
    // Exercise inherited pipes, not two nested Dart compilations within the
    // capture deadline. The native parent exits with both pipes held by sleep.
    final command = [
      '/bin/sh',
      '-c',
      r'''/bin/sleep 60 &
printf '%s' "$!" > "$1.pending"
/bin/mv "$1.pending" "$1"
printf '%s' "$$" > "$1.parent.pending"
/bin/mv "$1.parent.pending" "$1.parent"
printf out
printf err >&2
exit 0
''',
      'runtime-held-pipe',
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
