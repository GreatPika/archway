// Runs before pub get: keep this source-byte gate SDK-only.
import 'dart:convert';
import 'dart:io';

List<int> git(List<String> arguments) {
  final result = Process.runSync('git', arguments, stdoutEncoding: null);
  if (result.exitCode != 0) {
    throw ProcessException(
      'git',
      arguments,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as List<int>;
}

void main(List<String> arguments) {
  try {
    if (arguments.length != 1) {
      throw const FormatException('Usage: verify_export_sources.dart COMMIT');
    }
    final commit = utf8.decode(git(['rev-parse', 'HEAD'])).trim();
    if (commit != arguments.single) {
      throw const FormatException(
        'Checkout commit differs from the workflow source commit',
      );
    }
    final names = utf8.decode(
      git(['ls-files', '-z', 'assets/typescript', 'pubspec.lock']),
    );
    for (final name in names.split('\u0000').where((name) => name.isNotEmpty)) {
      final parts = name.split('/');
      final basename = parts.last;
      // pathlib suffix semantics: a lone dot-prefixed name has no extension.
      final dot = basename.lastIndexOf('.');
      final suffix = dot > 0 ? basename.substring(dot) : '';
      if (name == 'pubspec.lock' ||
          name.startsWith('assets/typescript/licenses/') ||
          (parts.length == 3 &&
              const ['.cjs', '.json', '.md'].contains(suffix))) {
        final actual = File(name).readAsBytesSync();
        final expected = git(['cat-file', 'blob', '$commit:$name']);
        if (actual.length != expected.length ||
            Iterable<int>.generate(actual.length)
                .any((index) => actual[index] != expected[index])) {
          throw FormatException('Export source bytes differ from Git: $name');
        }
      }
    }
    stdout.writeln(
      'Copied tracked assets and lockfiles match Git blobs at $commit',
    );
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
