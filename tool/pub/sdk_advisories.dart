// Measured Dart 3.13.3 client diagnostics; unknown diagnostics fail closed.
import 'stage.dart' show pubStageDependencies;

Map<String, Object> validatePubAdvisories(
  String stdout,
  String stderr,
  int exitCode, {
  required String version,
  required bool export,
}) {
  const heading =
      'Package validation found the following 7 potential issues:\n';
  if (stderr.isNotEmpty ||
      exitCode != (export ? 0 : 65) ||
      heading.allMatches(stdout).length != 1) {
    throw const FormatException(
      'Unexpected SDK validation status or diagnostics',
    );
  }
  final parts = stdout.split(heading);
  final preamble = RegExp(
    r'^Resolving dependencies(?: in `[^\r\n`]+`)?\.\.\.\nDownloading packages\.\.\.\n'
    r'(?<updates>(?:  [a-z][a-z0-9_]* [0-9][0-9A-Za-z.+-]* \([0-9][0-9A-Za-z.+-]* available\)\n)*)'
    r'Got dependencies(?: in `[^\r\n`]+`)?!\n'
    r'(?:(?<count>[1-9][0-9]*) packages? ha(?:ve|s) newer versions incompatible with dependency constraints\.\n'
    r'Try `dart pub outdated` for more information\.\n)?'
    'Publishing archway ${RegExp.escape(version)} to https://pub\\.dev:\\n'
    r'(?:(?:│   |    )*[├└]── [^\r\n]+\n)+\n'
    r'Total compressed archive size: (?:<1|[0-9]+(?:\.[0-9]+)?) (?:B|KB|MB)\.\n'
    r'Validating package\.\.\.\n$',
  ).firstMatch(parts.first);
  final expected = pubStageDependencies.entries
      .map(
        (entry) =>
            '* Your dependency on "${entry.key}" should allow more than one version. For example:\n'
            '  \n  dependencies:\n    ${entry.key}: ^${entry.value}\n  \n'
            '  Constraints that are too tight will make it difficult for people to use your package\n'
            '  along with other packages that also depend on "${entry.key}".\n',
      )
      .join('\n');
  if (preamble == null ||
      '\n'.allMatches(preamble.namedGroup('updates')!).length !=
          int.parse(preamble.namedGroup('count') ?? '0') ||
      !parts.last.startsWith(expected)) {
    throw const FormatException('SDK preamble or pinned advisories differ');
  }
  final tail = parts.last.substring(expected.length).trim();
  final validTail = export
      ? RegExp(r'^Wrote package archive at [^\r\n]+$').hasMatch(tail)
      : tail ==
            'The server may enforce additional checks.\n\nPackage has 7 warnings.';
  if (!validTail)
    throw const FormatException('Unexpected additional SDK diagnostics');
  return {'exit_code': exitCode, 'expected_advisories': 7};
}
