import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final package = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  final version = package['version'] as String;
  final tag = 'v$version';
  test('package and executable declare the initial release version', () async {
    expect(version, '0.1.0');
    expect(archwayVersion, version);
    expect(package['publish_to'], 'none');
    final out = StringBuffer(), err = StringBuffer();
    expect(await CLI().run(['--version'], CliStreams(out, err)), 0);
    expect(out.toString(), 'archway $version\n');
    expect(err.toString(), isEmpty);
  });
  test('installation documentation pins the same release tag', () {
    for (final name in ['README.md', 'contracts/compatibility/delivery.md']) {
      final text = File(name).readAsStringSync();
      expect(text, contains('ref: $tag'));
      expect(text, isNot(contains('ref: dart-only')));
    }
  });
  test('current package and bridge workflows target main', () {
    for (final name in ['dart-package', 'rebuild-macos-bridge']) {
      final workflow = loadYaml(
        File('.github/workflows/$name.yml').readAsStringSync(),
      ) as YamlMap;
      expect(workflow['on']['push']['branches'], ['main']);
      expect(workflow['permissions']['contents'], 'read');
    }
    final packageWorkflow = loadYaml(
      File('.github/workflows/dart-package.yml').readAsStringSync(),
    ) as YamlMap;
    expect(packageWorkflow['on']['push']['tags'], ['v*']);
    final bridgeWorkflow = loadYaml(
      File('.github/workflows/rebuild-macos-bridge.yml').readAsStringSync(),
    ) as YamlMap;
    expect(
      bridgeWorkflow['jobs']['build']['if'],
      "github.ref == 'refs/heads/main'",
    );
  });
  test('changelog has one initial release', () {
    final headings = RegExp(r'^## (.+)$', multiLine: true)
        .allMatches(File('CHANGELOG.md').readAsStringSync())
        .map((m) => m[1])
        .toList();
    expect(headings, ['$version']);
  });
}
