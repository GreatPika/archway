// Compiled AOT transport fixture, not an Archway core acceptance substitute.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final input = await stdin.transform(utf8.decoder).join();
  stdout.writeln(jsonEncode({'args': args, 'stdin': input}));
  stderr.writeln('native stderr');
  exitCode = 37;
}
