// Exact offline wrapper preparation under the already admitted Node runtime.
import 'package:path/path.dart' as p;

List<String> sourceNpmCommand(String node, String snapshot, p.Context paths) {
  if (!paths.isAbsolute(node) ||
      !paths.isAbsolute(snapshot) ||
      node.contains('\u0000') ||
      snapshot.contains('\u0000')) {
    throw const FormatException(
      'Source npm preparation requires absolute paths',
    );
  }
  final npm = paths.style == p.Style.windows
      ? paths.join(
          paths.dirname(node),
          'node_modules',
          'npm',
          'bin',
          'npm-cli.js',
        )
      : paths.join(
          paths.dirname(paths.dirname(node)),
          'lib',
          'node_modules',
          'npm',
          'bin',
          'npm-cli.js',
        );
  return [
    node,
    npm,
    'ci',
    '--prefix',
    paths.join(snapshot, 'tool', 'npm'),
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
  ];
}
