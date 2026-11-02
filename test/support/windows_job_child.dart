// Job-tree fixture: publish a real descendant PID before optional bad readiness.
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4)
    throw ArgumentError('Expected witness, ready, mode, child');
  final child = await Process.start(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'run',
    arguments[3],
  ]);
  child.stdout.drain<void>();
  child.stderr.drain<void>();
  final pending = File('${arguments[0]}.pending');
  pending.writeAsStringSync('${child.pid}');
  pending.renameSync(arguments[0]);
  if (arguments[2] == 'malformed-readiness') {
    File(arguments[1]).writeAsStringSync('invalid json');
  }
  await Future<void>.delayed(const Duration(seconds: 60));
}
