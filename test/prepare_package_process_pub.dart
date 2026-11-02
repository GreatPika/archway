// Maintainer-only dependency preparation, separate from application inspection.
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

Future<void> prepareGitFixture(
  Directory base,
  String dart,
  Map<String, String> environment,
) async {
  if (FileSystemEntity.typeSync(base.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('Git fixture output must be fresh', base.path);
  }
  base.createSync(recursive: true);
  final preparation = Directory(p.join(base.path, '.preparation'))
    ..createSync();
  final hooks = Directory(p.join(preparation.path, 'empty-hooks'))
    ..createSync();
  final config = File(p.join(preparation.path, 'empty-gitconfig'))
    ..createSync();
  final selectedEnvironment = {
    for (final entry in environment.entries)
      if (!entry.key.toUpperCase().startsWith('GIT_')) entry.key: entry.value,
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': config.path,
    'GIT_CONFIG_COUNT': '1',
    'GIT_CONFIG_KEY_0': 'core.hooksPath',
    'GIT_CONFIG_VALUE_0': hooks.path,
    'GIT_TERMINAL_PROMPT': '0',
    'CI': 'true',
    'DASH__SUPPRESS_ANALYTICS': 'true',
  };
  writePreparation(
    File(p.join(base.path, 'pubspec.yaml')),
    'name: fixture\nenvironment:\n  sdk: ^3.13.0\n'
    'dependencies:\n  path:\n    git:\n'
    '      url: $fixtureGitUrl\n      ref: $fixtureGitRef\n'
    '      path: pkgs/path\n',
  );
  await runPreparation(
    [dart, '--suppress-analytics', 'pub', 'get'],
    selectedEnvironment,
    File(p.join(preparation.path, 'pub-get.log')),
    cwd: base,
  );
}

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--git') {
    await prepareGitFixture(
      Directory(args[1]).absolute,
      File(args[2]).absolute.path,
      Platform.environment,
    );
    stdout.writeln(
      'Real pinned Git fixture prepared; no CLI checks performed.',
    );
    return;
  }
  if (args.length != 2) {
    throw ArgumentError(
      'Usage: prepare_package_process_pub.dart [--git] BASE DART',
    );
  }
  await preparePubFixtures(
    Directory(args[0]).absolute,
    File(args[1]).absolute.path,
    Platform.environment,
  );
  stdout.writeln(
    'Three real offline pub fixtures prepared; no CLI checks performed.',
  );
}
