import 'dart:io';

import 'windows_console.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 1) throw ArgumentError('Expected target PID');
    await sendWindowsCtrlC(int.parse(arguments.single));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
