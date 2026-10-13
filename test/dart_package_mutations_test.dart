import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

import 'dart_package_origins_test.dart'
    show hostedFixture, copyTree, gitFixture;
import 'dart_workspace_test.dart' show workspaceFixture;

void main() {
  for (final input in [
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
    'pubspec_overrides.yaml',
    'lib/pubspec.yaml',
    'target pubspec',
  ]) {
    test(
      'pub classifier rechecks $input and preserves independent facts',
      () async {
        final (root, dependency) = await isolatedHosted();
        await File('${root.path}/lib/app/main.dart').writeAsString(
          "import 'package:collection/collection.dart'; import '../core/private.dart'; import 'dart:io';",
        );
        final file = File(
          input == 'target pubspec'
              ? '${dependency.path}/pubspec.yaml'
              : '${root.path}/$input',
        );
        final report = await mutate(root, () {
          file.writeAsStringSync(
            file.existsSync()
                ? '${file.readAsStringSync()}\n '
                : 'name: appeared\n',
          );
        });
        expect(
          report['payload']['facts']['edges'].map(
            (e) => e['resolution']['kind'],
          ),
          ['external', 'local', 'builtin'],
        );
        expect(
          report['payload']['violations'].single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
        final expected = input == 'target pubspec'
            ? {'kind': 'external', 'canonical_file_uri': file.uri.toString()}
            : {'kind': 'repository', 'path': input};
        expect(
          report['payload']['input_identity']['changed_inputs'],
          contains(equals(expected)),
        );
      },
    );
  }

  test(
    'an absent required pub lock is recorded and creation is detected',
    () async {
      final root = await hostedFixture();
      final lock = File('${root.path}/pubspec.lock');
      final saved = await lock.readAsString();
      await lock.delete();
      await File('${root.path}/lib/app/main.dart').writeAsString(
        "import 'package:collection/collection.dart'; import '../core/private.dart';",
      );
      final report = await mutate(root, () => lock.writeAsStringSync(saved));
      expect(
        report['payload']['input_identity']['changed_inputs'],
        contains(equals({'kind': 'repository', 'path': 'pubspec.lock'})),
      );
      expect(
        report['payload']['facts']['edges'].map((e) => e['resolution']['kind']),
        ['unresolved', 'local'],
      );
      expect(
        report['payload']['violations'].single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      expect(
        report['payload']['input_identity']['inputs'],
        contains(
          allOf(
            containsPair('presence', 'absent'),
            containsPair('location', {
              'kind': 'repository',
              'path': 'pubspec.lock',
            }),
          ),
        ),
      );
    },
  );

  for (final input in [
    'pubspec.yaml',
    'packages/core/pubspec.yaml',
    'pubspec_overrides.yaml',
    'packages/core/pubspec_overrides.yaml',
  ]) {
    test(
      'effective workspace input $input is observed and rechecked',
      () async {
        final root = await workspaceFixture();
        await File('${root.path}/packages/app/lib/main.dart')
            .writeAsString("import 'package:core/value.g.dart';");
        final file = File('${root.path}/$input');
        final report = await mutate(
          root,
          () => file.writeAsStringSync(
            file.existsSync()
                ? '${file.readAsStringSync()}\n# changed\n'
                : '{}',
          ),
        );
        expect(
          report['payload']['facts']['edges'].single['resolution']['kind'],
          'local',
        );
        expect(
          report['payload']['violations'].single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
        expect(
          report['payload']['input_identity']['changed_inputs'],
          contains(equals({'kind': 'repository', 'path': input})),
        );
      },
    );
  }

  test(
    'selected package config alias is rechecked after retargeting',
    () async {
      final root = await hostedFixture();
      final file = File('${root.path}/.dart_tool/package_config.json');
      await file.copy('${root.path}/.dart_tool/first.json');
      await file.copy('${root.path}/.dart_tool/second.json');
      await file.delete();
      final alias = Link(file.path);
      await alias.create('first.json');
      final report = await mutate(root, () => alias.updateSync('second.json'));
      expect(report['payload']['input_identity']['aliases'], isNotEmpty);
      expect(
        report['payload']['input_identity']['changed_inputs'],
        contains(
          equals({
            'kind': 'repository',
            'path': '.dart_tool/package_config.json',
          }),
        ),
      );
    },
  );

  for (final input in ['HEAD', 'checkout config', 'cache config']) {
    test(
      'prepared Git $input is observed and rechecked without running Git',
      () async {
        final (root, checkout, cache) = await isolatedGit();
        final file = File(switch (input) {
          'HEAD' => '${checkout.path}/.git/HEAD',
          'checkout config' => '${checkout.path}/.git/config',
          _ => '${cache.path}/config',
        });
        final report = await mutate(
          root,
          () => file.writeAsStringSync('${file.readAsStringSync()}\n'),
        );
        expect(
          report['payload']['facts']['edges'].single['resolution']['kind'],
          'external',
        );
        expect(
          report['payload']['input_identity']['changed_inputs'],
          contains(
            equals({
              'kind': 'external',
              'canonical_file_uri': file.uri.toString(),
            }),
          ),
        );
      },
      skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
          ? 'Requires prepared Git fixture.'
          : false,
    );
  }
}

Future<Map> mutate(Directory root, void Function() change) async {
  final out = StringBuffer(), err = StringBuffer();
  final exit = await runZoned(
    () => CLI().run(['--root', root.path, 'check'], CliStreams(out, err)),
    zoneValues: {#archwayBeforeInputRecheck: change},
  );
  final report = jsonDecode(out.toString()) as Map;
  expect(exit, 2, reason: out.toString());
  expect(report['status'], 'incomplete');
  expect(err.toString(), '');
  expect(out.toString().split('\n'), hasLength(2));
  expect(report['payload']['analysis_complete'], false);
  expect(report['payload']['input_identity']['rechecked'], true);
  expect(report['payload']['input_identity']['changed_inputs'], isNotEmpty);
  return report;
}

Future<(Directory, Directory)> isolatedHosted() async {
  final root = await hostedFixture();
  final file = File('${root.path}/.dart_tool/package_config.json');
  final config = jsonDecode(await file.readAsString()) as Map;
  final entry = (config['packages'] as List).singleWhere(
    (e) => e['name'] == 'collection',
  );
  final dependency = await Directory.systemTemp.createTemp(
    'archway-hosted-copy-',
  );
  addTearDown(() => dependency.delete(recursive: true));
  await copyTree(
    Directory(Uri.parse(entry['rootUri']).toFilePath()),
    dependency,
  );
  entry['rootUri'] = dependency.uri.toString();
  await file.writeAsString(jsonEncode(config));
  return (root, dependency);
}

Future<(Directory, Directory, Directory)> isolatedGit() async {
  final root = await gitFixture();
  final file = File('${root.path}/.dart_tool/package_config.json');
  final config = jsonDecode(await file.readAsString()) as Map;
  final entry = (config['packages'] as List).singleWhere(
    (e) => e['name'] == 'path',
  );
  final original = Directory(Uri.parse(entry['rootUri']).toFilePath());
  final checkout = await Directory.systemTemp.createTemp('archway-git-copy-');
  addTearDown(() => checkout.delete(recursive: true));
  final cache = Directory('${checkout.path}/bare-cache');
  await cache.create();
  await copyTree(original, Directory('${checkout.path}/pkgs/path'));
  final originalGit = '${original.parent.parent.path}/.git';
  await Directory('${checkout.path}/.git').create();
  await File('$originalGit/HEAD').copy('${checkout.path}/.git/HEAD');
  final content = await File('$originalGit/config').readAsString();
  final origin = RegExp(r'url = (.+)').firstMatch(content)![1]!;
  await File('$origin/config').copy('${cache.path}/config');
  await File('${checkout.path}/.git/config')
      .writeAsString(content.replaceFirst(origin, cache.path));
  entry['rootUri'] = Directory('${checkout.path}/pkgs/path').uri.toString();
  await file.writeAsString(jsonEncode(config));
  return (root, checkout, cache);
}
