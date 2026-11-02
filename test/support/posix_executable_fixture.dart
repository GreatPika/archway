import 'dart:io';

/// Write in a separate process so concurrent test-isolate forks cannot inherit
/// a writable descriptor and make Linux reject execution with ETXTBSY.
Future<void> writePosixExecutableFixture(File file, String contents) async {
  final arguments = [
    '-c',
    r'printf "%s" "$2" > "$1"',
    'fixture-writer',
    file.path,
    contents,
  ];
  final result = await Process.run('/bin/sh', arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      '/bin/sh',
      arguments,
      result.stderr as String,
      result.exitCode,
    );
  }
}
