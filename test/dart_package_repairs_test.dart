import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_package_origins_test.dart' show hostedFixture, prepare;

void main() {
  test(
    'nested workspace must not become external with stale hosted row',
    () async {
      final root = await hostedFixture();
      final lock = await File('${root.path}/pubspec.lock').readAsString();
      final manifest = File('${root.path}/pubspec.yaml');
      await manifest.writeAsString(
        '${await manifest.readAsString()}workspace:\n  - packages/middle\n',
      );
      final middle = Directory('${root.path}/packages/middle');
      final nested = Directory('${middle.path}/nested');
      await Directory('${nested.path}/lib').create(recursive: true);
      await File('${middle.path}/pubspec.yaml').writeAsString(
        'name: middle\nenvironment:\n  sdk: ^3.13.0\nresolution: workspace\nworkspace:\n  - nested\n',
      );
      await File('${nested.path}/pubspec.yaml').writeAsString(
        'name: collection\nversion: 1.19.1\nenvironment:\n  sdk: ^3.13.0\nresolution: workspace\n',
      );
      await File('${nested.path}/lib/collection.dart')
          .writeAsString('class LocalCollection {}');
      final effectiveManifest = await manifest.readAsString();
      await manifest.writeAsString(
        effectiveManifest.replaceFirst(
          'dependencies:\n  collection: 1.19.1\n',
          '',
        ),
      );
      await File('${root.path}/pubspec.lock').delete();
      await File('${root.path}/.dart_tool/package_config.json').delete();
      await prepare(root);
      await manifest.writeAsString(effectiveManifest);
      await File('${root.path}/pubspec.lock').writeAsString(lock);
      await File('${root.path}/lib/app/main.dart').writeAsString(
        "import 'package:collection/collection.dart'; import '../core/private.dart'; import 'dart:io';",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(report.status, 'incomplete', reason: jsonEncode(report.payload));
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
  test('an effective version override cannot reuse an incompatible hosted instance', () async {
    final root = await hostedFixture();
    await File('${root.path}/pubspec_overrides.yaml')
        .writeAsString('dependency_overrides:\n  collection: 9.9.9\n');
    await File('${root.path}/lib/app/main.dart').writeAsString(
      "import 'package:collection/collection.dart'; import '../core/private.dart'; import 'dart:io';",
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete', reason: jsonEncode(report.payload));
    expect(
      (report.payload['facts'] as Map)['edges'].map(
        (e) => e['resolution']['kind'],
      ),
      ['unresolved', 'local', 'builtin'],
    );
    expect(
      (report.payload['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
  });

  for (final constraint in [
    '9.9.9',
    '^2.0.0',
    '>=2.0.0 <3.0.0',
    'not-a-version',
  ]) {
    test(
      'ordinary effective constraint $constraint must agree with the installed version',
      () async {
        final root = await hostedFixture();
        final manifest = File('${root.path}/pubspec.yaml');
        await manifest.writeAsString(
          (await manifest.readAsString()).replaceFirst(
            'collection: 1.19.1',
            'collection: "$constraint"',
          ),
        );
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
          'kind': 'unresolved',
        });
      },
    );
  }
  for (final constraint in ['^1.19.0', '>=1.0.0 <2.0.0', 'any']) {
    test(
      'a compatible effective range $constraint preserves the prepared external instance',
      () async {
        final root = await hostedFixture();
        final manifest = File('${root.path}/pubspec.yaml');
        await manifest.writeAsString(
          (await manifest.readAsString()).replaceFirst(
            'collection: 1.19.1',
            'collection: 9.9.9',
          ),
        );
        await File('${root.path}/pubspec_overrides.yaml').writeAsString(
          'dependency_overrides:\n  collection:\n    version: "$constraint"\n',
        );
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'ok', reason: jsonEncode(report.payload));
        expect(
          (report.payload['facts'] as Map)['edges']
              .single['resolution']['kind'],
          'external',
        );
      },
    );
  }
  test(
    'a mapping-form version override cannot bypass constraint validation',
    () async {
      final root = await hostedFixture();
      await File('${root.path}/pubspec_overrides.yaml').writeAsString(
        'dependency_overrides:\n  collection:\n    version: ^2.0.0\n',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
        'kind': 'unresolved',
      });
    },
  );
  test('shared workspace version constraints cannot contradict the installed instance', () async {
    final root = await hostedFixture();
    final manifest = File('${root.path}/pubspec.yaml');
    await manifest.writeAsString(
      '${await manifest.readAsString()}workspace: [member]\n',
    );
    await Directory('${root.path}/member').create();
    final member = File('${root.path}/member/pubspec.yaml');
    await member.writeAsString(
      'name: member\nresolution: workspace\nenvironment:\n  sdk: ^3.13.0\ndependencies:\n  collection: ^1.19.0\n',
    );
    await prepare(root);
    await member.writeAsString(
      (await member.readAsString()).replaceFirst('^1.19.0', '^2.0.0'),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
      'kind': 'unresolved',
    });
  });
  for (final location in ['', 'member/']) {
    test(
      'real prepared ${location}override supersedes incompatible ordinary workspace constraints',
      () async {
        final root = await hostedFixture();
        final manifest = File('${root.path}/pubspec.yaml');
        await manifest.writeAsString(
          '${(await manifest.readAsString()).replaceFirst('collection: 1.19.1', 'collection: 9.9.9')}workspace: [member]\n',
        );
        await Directory('${root.path}/member').create();
        await File('${root.path}/member/pubspec.yaml').writeAsString(
          'name: member\nresolution: workspace\nenvironment:\n  sdk: ^3.13.0\ndependencies:\n  collection: ^2.0.0\n',
        );
        await File('${root.path}/${location}pubspec_overrides.yaml')
            .writeAsString('dependency_overrides:\n  collection: ^1.19.0\n');
        await prepare(root);
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'ok', reason: jsonEncode(report.payload));
        expect(
          (report.payload['facts'] as Map)['edges']
              .single['resolution']['kind'],
          'external',
        );
      },
    );
  }
}
