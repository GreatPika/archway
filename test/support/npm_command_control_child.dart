// Opaque streams for probe lifecycle tests, not Archway command acceptance.
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  stdout.writeln(jsonEncode(arguments));
  if (!['validate', 'node', 'export'].contains(arguments[2])) exitCode = 64;
}
