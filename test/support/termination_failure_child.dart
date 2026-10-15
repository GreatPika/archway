// Malformed barrier negative control: both cleanup paths genuinely exist.
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final base = arguments.single;
  File('$base/npm termination ready.pending').writeAsStringSync('unfinished');
  File('$base/npm termination ready.json').writeAsStringSync('{"core":0}');
  await Future<void>.delayed(const Duration(seconds: 30));
}
