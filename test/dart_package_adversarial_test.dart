import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture;
import 'dart_workspace_test.dart' show workspaceFixture;
import 'dart_package_mutations_test.dart' show isolatedGit;
import 'dart_package_origins_test.dart'
    show hostedFixture, pathFixture, gitFixture, copyTree;

void main() {
  test(
    'proven path package aliases retain local provenance and input aliases',
    () async {
      final root = await pathFixture();
      final configFile = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await configFile.readAsString()) as Map;
      final entry = (config['packages'] as List).singleWhere(
        (e) => e['name'] == 'outside_pkg',
      );
      final original = configFile.uri.resolve(entry['rootUri']);
      await Link('${root.path}/dependency-alias').create(original.toFilePath());
      entry['rootUri'] = '../dependency-alias/';
      await configFile.writeAsString(jsonEncode(config));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative', reason: jsonEncode(report.payload));
      expect(
        (report.payload['facts'] as Map)['edges'].single['resolution']['kind'],
        'local',
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'LOCAL_TARGET_OUTSIDE_SCOPE',
      );
      expect((report.payload['input_identity'] as Map)['aliases'], isNotEmpty);
    },
  );
  for (final damage in [
    'missing lock',
    'version',
    'description name',
    'configured root',
  ]) {
    test(
      'hosted $damage stays incomplete beside independent local and SDK facts',
      () async {
        final root = await hostedFixture();
        final lock = File('${root.path}/pubspec.lock');
        if (damage == 'missing lock') {
          await lock.delete();
        } else if (damage == 'version') {
          await lock.writeAsString(
            (await lock.readAsString()).replaceFirst('1.19.1', '9.9.9'),
          );
        } else if (damage == 'description name') {
          await lock.writeAsString(
            (await lock.readAsString()).replaceFirst(
              'name: collection',
              'name: other',
            ),
          );
        } else {
          final configFile = File(
            '${root.path}/.dart_tool/package_config.json',
          );
          final config = jsonDecode(await configFile.readAsString()) as Map;
          (config['packages'] as List).singleWhere(
            (e) => e['name'] == 'collection',
          )['rootUri'] = '../fake/';
          await configFile.writeAsString(jsonEncode(config));
          await Directory('${root.path}/fake/lib').create(recursive: true);
          await File('${root.path}/fake/pubspec.yaml')
              .writeAsString('name: other\nversion: 1.19.1\n');
          await File('${root.path}/fake/lib/collection.dart')
              .writeAsString('class Fake {}');
        }
        await File('${root.path}/lib/app/main.dart').writeAsString(
          "import 'package:collection/collection.dart'; import '../core/private.dart'; import 'dart:io';",
        );
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        final edges = (report.payload['facts'] as Map)['edges'] as List;
        expect(edges.map((e) => e['resolution']['kind']), [
          'unresolved',
          'local',
          'builtin',
        ]);
        expect(
          (report.payload['violations'] as List).single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
      },
    );
  }

  test(
    'an in-root configured package cannot borrow the source self identity',
    () async {
      final root = await dartFixture(
        main: "import 'package:pretender/value.dart'; import '../core/private.dart';",
      );
      await Directory('${root.path}/vendored/lib').create(recursive: true);
      await File('${root.path}/vendored/pubspec.yaml')
          .writeAsString('name: pretender\nversion: 1.0.0\n');
      await File('${root.path}/vendored/lib/value.dart')
          .writeAsString('class Value {}');
      final file = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      (config['packages'] as List).add({
        'name': 'pretender',
        'rootUri': '../vendored/',
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      });
      await file.writeAsString(jsonEncode(config));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['facts'] as Map)['edges'].map(
          (e) => e['resolution']['kind'],
        ),
        ['unresolved', 'local'],
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );

  for (final damage in [
    'local Git URL',
    'wrong Git subpath',
    'wrong Git commit',
  ]) {
    test(
      '$damage cannot prove a remote installed origin',
      () async {
        final root = await gitFixture();
        final lock = File('${root.path}/pubspec.lock');
        final original = await lock.readAsString();
        await lock.writeAsString(switch (damage) {
          'local Git URL' => original.replaceFirst(
            'https://github.com/dart-lang/core.git',
            'file:///tmp/local-core',
          ),
          'wrong Git subpath' => original.replaceFirst(
            'pkgs/path',
            'pkgs/other',
          ),
          _ => original.replaceFirst(
            'resolved-ref: "4d80610a878cdb3f9f10e6a16a2af6631251a3c6"',
            'resolved-ref: "0000000000000000000000000000000000000000"',
          ),
        });
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
          'kind': 'unresolved',
        });
      },
      skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
          ? 'Requires prepared Git fixture.'
          : false,
    );
  }
  test(
    'a conflicting effective hosted URL cannot borrow a cached instance',
    () async {
      final root = await hostedFixture();
      await File('${root.path}/pubspec_overrides.yaml').writeAsString(
        'dependency_overrides:\n  collection:\n    hosted: https://other.example\n    version: 1.19.1\n',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
        'kind': 'unresolved',
      });
    },
  );

  test('workspace membership cannot override a conflicting effective path override', () async {
    final root = await workspaceFixture();
    await File('${root.path}/pubspec_overrides.yaml')
        .writeAsString('dependency_overrides:\n  core:\n    path: elsewhere\n');
    await File('${root.path}/packages/app/lib/main.dart')
        .writeAsString("import 'package:core/value.g.dart'; import 'dart:io';");
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      (report.payload['facts'] as Map)['edges'].map(
        (e) => e['resolution']['kind'],
      ),
      ['unresolved', 'builtin'],
    );
  });
  test(
    'an absolute file URI joins an aliased hosted package root',
    () async {
      final root = await hostedFixture();
      final file = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      final entry = (config['packages'] as List).singleWhere(
        (e) => e['name'] == 'collection',
      );
      final targetRoot = Uri.parse(entry['rootUri']).toFilePath();
      await Link('${root.path}/.dart_tool/hosted-alias').create(targetRoot);
      entry['rootUri'] = 'hosted-alias/';
      await file.writeAsString(jsonEncode(config));
      await File('${root.path}/lib/app/main.dart').writeAsString(
        "import '${File('$targetRoot/lib/collection.dart').uri}';",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'ok', reason: jsonEncode(report.payload));
      expect(
        (report.payload['facts'] as Map)['edges'].single['resolution']['kind'],
        'external',
      );
    },
  );

  for (final remote in [
    'ssh://git@github.com/dart-lang/core.git',
    'git://github.com/dart-lang/core.git',
    'git@github.com:dart-lang/core.git',
  ]) {
    test(
      'prepared Git metadata accepts remote spelling $remote',
      () async {
        final (root, _, cache) = await isolatedGit();
        // Adapt a real prepared instance's metadata only; this is a consistency
        // test, not a claim that the alternate transport was fetched here.
        for (final path in [
          '${root.path}/pubspec.yaml',
          '${root.path}/pubspec.lock',
          '${cache.path}/config',
        ]) {
          final file = File(path);
          await file.writeAsString(
            (await file.readAsString()).replaceAll(
              'https://github.com/dart-lang/core.git',
              remote,
            ),
          );
        }
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'ok', reason: jsonEncode(report.payload));
        expect(
          (report.payload['facts'] as Map)['edges']
              .single['resolution']['kind'],
          'external',
        );
      },
      skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
          ? 'Requires prepared Git fixture.'
          : false,
    );
  }

  test('Git cache origin dot segments retain verified remote provenance', () async {
    final (root, checkout, cache) = await isolatedGit();
    final config = File('${checkout.path}/.git/config');
    final cacheConfig = File('${cache.path}/config');
    final canonicalConfig = File(await cacheConfig.resolveSymbolicLinks());
    final origin = '${cache.path}/.';
    expect(
      await Directory(origin).resolveSymbolicLinks(),
      await cache.resolveSymbolicLinks(),
    );
    await config.writeAsString(
      (await config.readAsString()).replaceFirst(cache.path, origin),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok', reason: jsonEncode(report.payload));
    expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
      'kind': 'external',
      'identity': 'package:path/path.dart',
    });
    expect(
      (report.payload['input_identity'] as Map)['inputs'],
      contains(allOf(
        containsPair('location', {
          'kind': 'external',
          'canonical_file_uri': canonicalConfig.uri.toString(),
        }),
        containsPair('presence', 'present'),
      )),
    );
  }, skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
      ? 'Requires prepared Git fixture.'
      : false);

  for (final subpath in [r'pkgs\path', '../pkgs/path', 'C:/pkgs/path']) {
    test('Git subpath $subpath cannot replace portable lock metadata', () async {
      final (root, _, _) = await isolatedGit();
      // Change the declaration and lock together so mismatch alone cannot
      // account for rejection of a nonportable or escaping Git subpath.
      for (final name in ['pubspec.yaml', 'pubspec.lock']) {
        final file = File('${root.path}/$name');
        final text = await file.readAsString();
        expect(text, contains('pkgs/path'));
        await file.writeAsString(text.replaceFirst(
          RegExp(r'path: (?:(?:"pkgs/path")|pkgs/path)'),
          "path: '$subpath'",
        ));
      }
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
        'kind': 'unresolved',
      });
    }, skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
        ? 'Requires prepared Git fixture.'
        : false);
  }

  test(
    'missing nested installed manifest cannot borrow an enclosing self package',
    () async {
      final root = await hostedFixture();
      final file = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      final entry = (config['packages'] as List).singleWhere(
        (e) => e['name'] == 'collection',
      );
      await copyTree(
        Directory('${Uri.parse(entry['rootUri']).toFilePath()}/lib'),
        Directory('${root.path}/lib/app/vendor/collection/lib'),
      );
      entry['rootUri'] = '../lib/app/vendor/collection/';
      await file.writeAsString(jsonEncode(config));
      final policy = File('${root.path}/architecture.yaml');
      await policy.writeAsString(
        (await policy.readAsString()).replaceFirst(
          'exclude: []',
          'exclude: [lib/app/vendor/]',
        ),
      );
      await File('${root.path}/lib/app/main.dart').writeAsString(
        "import 'vendor/collection/lib/collection.dart'; import '../core/private.dart';",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['facts'] as Map)['edges'].map(
          (e) => e['resolution']['kind'],
        ),
        ['unresolved', 'local'],
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );
}
