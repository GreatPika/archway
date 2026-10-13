// Maintainer-only offline preparation, separate from AOT checks.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/ci/native_fixture_pins.dart';
import '../tool/ci/preparation_process.dart';

Future<void> preparePubFixtures(
  Directory base,
  String dart,
  Map<String, String> environment,
) async {
  void write(String path, String value) =>
      writePreparation(File(p.join(base.path, path)), value);
  Future<void> prepare(String name) => runPreparation(
    [dart, '--suppress-analytics', 'pub', 'get', '--offline'],
    environment,
    File(p.join(base.path, name, 'preparation.log')),
    cwd: Directory(p.join(base.path, name)),
    timeout: const Duration(seconds: 90),
  );
  const spec = 'name: fixture\nenvironment:\n  sdk: ^3.13.0\n';
  write(
    'hosted/pubspec.yaml',
    '${spec}dependencies:\n  collection: $fixtureCollectionVersion\n',
  );
  await prepare('hosted');
  write(
    'outside/pubspec.yaml',
    'name: outside_pkg\nversion: 1.2.3\nenvironment:\n  sdk: ^3.13.0\n',
  );
  write('outside/lib/value.dart', 'class Value {}\n');
  write(
    'path/pubspec.yaml',
    '${spec}dependencies:\n  outside_pkg:\n    path: ../outside\n',
  );
  await prepare('path');
  write(
    'workspace/pubspec.yaml',
    'name: workspace_root\nenvironment:\n  sdk: ^3.13.0\nworkspace: [packages/app, packages/core]\n',
  );
  for (final name in ['app', 'core']) {
    write(
      'workspace/packages/$name/pubspec.yaml',
      'name: $name\nversion: 1.0.0\nresolution: workspace\nenvironment:\n  sdk: ^3.13.0\n${name == 'app' ? 'dependencies:\n  core: ^1.0.0\n' : ''}',
    );
  }
  write('workspace/packages/core/lib/value.dart', 'class Value {}\n');
  await prepare('workspace');
}

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw ArgumentError('Usage: prepare_package_process_pub.dart BASE DART');
  await preparePubFixtures(
    Directory(args[0]).absolute,
    File(args[1]).absolute.path,
    Platform.environment,
  );
  stdout.writeln(
    'Three real offline pub fixtures prepared; no CLI checks performed.',
  );
}
