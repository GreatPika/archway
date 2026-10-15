// Real two-phase fixture for acceptance capture; barriers keep PIDs alive until
// the observer has retained native handles. No installer or registry activity.
import 'dart:async';
import 'dart:io';

Future<void> waitFor(String path) async {
  final elapsed = Stopwatch()..start();
  while (!File(path).existsSync()) {
    if (elapsed.elapsed >= const Duration(seconds: 30)) {
      throw TimeoutException('Missing capture fixture barrier');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void publish(String path) {
  final pending = File('$path.pending')..writeAsStringSync('$pid', flush: true);
  pending.renameSync(path);
}

Future<void> main(List<String> args) async {
  final role = args[0], marker = args[1], mode = args[2];
  if (role == 'parent') {
    stdout.writeln('parent');
    await stdout.flush();
    await Process.start(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'run',
      Platform.script.toFilePath(),
      'descendant',
      marker,
      mode,
    ], mode: ProcessStartMode.inheritStdio);
    publish('$marker.parent');
    await waitFor('$marker.parent-release');
    exit(int.parse(args[3]));
  }
  stderr.writeln('descendant');
  await stderr.flush();
  if (mode == 'silent') await Future.wait([stdout.close(), stderr.close()]);
  publish('$marker.descendant');
  await waitFor('$marker.descendant-release');
}
