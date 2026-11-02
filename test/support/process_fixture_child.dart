// Long-lived readiness fixture for native lifecycle and suspended-launch tests.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  // Install the real POSIX handler before publishing the atomic ready marker.
  final interruptible =
      arguments.length == 2 && arguments.first == '--sigint-exit-23';
  final signal = interruptible
      ? ProcessSignal.sigint.watch().listen((_) => exit(23))
      : null;
  if (interruptible) arguments = arguments.skip(1).toList();
  if (arguments.isNotEmpty) {
    final marker = File(arguments.first);
    final pending = File('${marker.path}.pending');
    pending.writeAsStringSync(
      jsonEncode({
        'arguments': arguments.skip(1).toList(),
        'directory': Directory.current.path,
        'environment': Platform.environment['ARCHWAY_FIXTURE_VALUE'],
      }),
    );
    pending.renameSync(marker.path);
  }
  await Future<void>.delayed(const Duration(seconds: 60));
  await signal?.cancel();
}
