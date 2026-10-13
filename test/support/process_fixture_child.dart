// Long-lived readiness fixture for native lifecycle and suspended-launch tests.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
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
}
