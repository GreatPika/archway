// Separate process for native sharing-denial acceptance.
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 1) throw ArgumentError('Expected output path');
  File(arguments.single).writeAsStringSync('changed');
}
