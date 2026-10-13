import 'dart:async';
import 'dart:io';

import 'package:archway/src/bootstrap/bootstrap.dart';
import 'package:test/test.dart';

void main() {
  test('init preserves the legacy guide without migrating it', () async {
    final root = await Directory.systemTemp.createTemp('archway-legacy-');
    addTearDown(() => root.delete(recursive: true));
    final legacy = File('${root.path}/ARCHITECTURE_AGENT.md');
    await legacy.writeAsString('user-maintained legacy guide');
    final preview = await Bootstrap().initialize(root.path, 'dart', true);
    expect(preview.outcome, 'planned');
    expect(preview.plannedPaths, ['architecture.yaml', 'ARCHITECTURE.md']);
    expect(await root.list().length, 1);
    final result = await Bootstrap().initialize(root.path, 'dart', false);
    expect(result.outcome, 'created');
    expect(result.createdPaths, ['architecture.yaml', 'ARCHITECTURE.md']);
    expect(await legacy.readAsString(), 'user-maintained legacy guide');
    expect(await root.list().length, 3);
    expect(
      await File('${root.path}/ARCHITECTURE.md').readAsString(),
      preview.plannedFiles.last.content,
    );
  });

  test('existing guide files, directories and dangling links prevent all writes', () async {
    for (final kind in ['file', 'directory', 'link']) {
      for (final dryRun in [true, false]) {
        final root = await Directory.systemTemp.createTemp('archway-guide-');
        addTearDown(() => root.delete(recursive: true));
        final target = '${root.path}/ARCHITECTURE.md';
        if (kind == 'file') await File(target).writeAsString('user guide');
        if (kind == 'directory') await Directory(target).create();
        if (kind == 'link') await Link(target).create('missing-guide');
        final before = await FileSystemEntity.type(target, followLinks: false);
        final result = await Bootstrap().initialize(root.path, 'mixed', dryRun);
        expect(result.outcome, 'conflict');
        expect(result.conflictingPaths, ['ARCHITECTURE.md']);
        expect(result.createdPaths, isEmpty);
        expect(result.residualPaths, isEmpty);
        expect(result.plannedFiles, hasLength(dryRun ? 2 : 0));
        expect(await FileSystemEntity.type(target, followLinks: false), before);
        if (kind == 'file') expect(await File(target).readAsString(), 'user guide');
        if (kind == 'link') expect(await Link(target).target(), 'missing-guide');
        expect(await root.list().length, 1);
      }
    }
  });

  test('ASCII-case startup collisions are refused before any write on every OS', () async {
    for (final entry in {
      'architecture.md': 'ARCHITECTURE.md',
      'ArChItEcTuRe.Md': 'ARCHITECTURE.md',
      'ARCHITECTURE.YAML': 'architecture.yaml',
    }.entries) {
      for (final dryRun in [true, false]) {
        final root = await Directory.systemTemp.createTemp('archway-case-');
        addTearDown(() => root.delete(recursive: true));
        final existing = File('${root.path}/${entry.key}');
        await existing.writeAsString('keep original');
        final result = await Bootstrap().initialize(root.path, 'mixed', dryRun);
        expect(result.outcome, 'conflict');
        expect(result.conflictingPaths, [entry.value]);
        expect(result.createdPaths, isEmpty);
        expect(result.residualPaths, isEmpty);
        expect(result.plannedFiles, hasLength(dryRun ? 2 : 0));
        expect(result.diagnostics.single.path, entry.value);
        expect(result.diagnostics.single.message, contains(entry.key));
        expect(await existing.readAsString(), 'keep original');
        expect(await root.list().length, 1);
      }
    }
  });

  test(
    'dry-run reports every preflight conflict without altering targets',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-conflict-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString('keep policy');
      await Directory('${root.path}/ARCHITECTURE.md').create();
      final result = await Bootstrap().initialize(root.path, 'mixed', true);
      expect(result.outcome, 'conflict');
      expect(result.conflictingPaths, [
        'architecture.yaml',
        'ARCHITECTURE.md',
      ]);
      expect(result.plannedFiles, hasLength(2));
      expect(result.createdPaths, isEmpty);
      expect(
        await File('${root.path}/architecture.yaml').readAsString(),
        'keep policy',
      );
    },
  );

  test(
    'normal init exclusively creates exactly the two previewed files',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-create-');
      addTearDown(() => root.delete(recursive: true));
      final preview = await Bootstrap().initialize(
        root.path,
        'typescript',
        true,
      );
      final result = await Bootstrap().initialize(
        root.path,
        'typescript',
        false,
      );
      expect(result.outcome, 'created');
      expect(result.createdPaths, [
        'architecture.yaml',
        'ARCHITECTURE.md',
      ]);
      expect(result.plannedFiles, isEmpty);
      expect(result.residualPaths, isEmpty);
      expect(await root.list().length, 2);
      for (final file in preview.plannedFiles) {
        expect(
          await File('${root.path}/${file.path}').readAsString(),
          file.content,
        );
      }
    },
  );

  test(
    'failure before first exclusive create rolls back without residual files',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-first-fail-');
      addTearDown(() => root.delete(recursive: true));
      final result = await runZoned(
        () => Bootstrap().initialize(root.path, 'dart', false),
        zoneValues: {
          #archwayBootstrapFault: (String stage, String path) {
            if (stage == 'beforeCreate')
              throw FileSystemException('Injected create failure', path);
          },
        },
      );
      expect(result.outcome, 'rolled_back');
      expect(result.createdPaths, isEmpty);
      expect(result.residualPaths, isEmpty);
      expect(result.diagnostics.single.code, 'INIT_WRITE_FAILED');
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('second write failure preserves both created paths and explicit Linux residuals', () async {
    final root = await Directory.systemTemp.createTemp('archway-second-fail-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'dart', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforeWrite' && path == 'ARCHITECTURE.md')
            throw const FileSystemException('Injected write failure');
        },
      },
    );
    expect(result.diagnostics.first.code, 'INIT_WRITE_FAILED');
    expect(result.diagnostics.first.path, 'ARCHITECTURE.md');
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml', 'ARCHITECTURE.md']);
    expect(result.residualPaths, result.createdPaths);
    expect(
      result.diagnostics.map((d) => d.code),
      containsAll(['INIT_WRITE_FAILED', 'INIT_ROLLBACK_FAILED']),
    );
    expect(
      await File('${root.path}/architecture.yaml').readAsString(),
      contains('version: 1'),
    );
    expect(await File('${root.path}/ARCHITECTURE.md').length(), 0);
  });

  test('exclusive-create race keeps the other writer file and reports its conflict', () async {
    final root = await Directory.systemTemp.createTemp('archway-race-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'mixed', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforeCreate' && path == 'ARCHITECTURE.md')
            File('${root.path}/$path').writeAsStringSync('other writer');
        },
      },
    );
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml']);
    expect(result.residualPaths, ['architecture.yaml']);
    expect(result.conflictingPaths, ['ARCHITECTURE.md']);
    expect(
      await File('${root.path}/ARCHITECTURE.md').readAsString(),
      'other writer',
    );
  });

  test('replacement during failed init is never overwritten or deleted by rollback', () async {
    final root = await Directory.systemTemp.createTemp('archway-replacement-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'mixed', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforeCreate' && path == 'ARCHITECTURE.md') {
            final policy = File('${root.path}/architecture.yaml');
            policy.deleteSync();
            policy.writeAsStringSync('replacement belongs to someone else');
            throw FileSystemException('Injected second create failure', path);
          }
        },
      },
    );
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml']);
    expect(result.residualPaths, ['architecture.yaml']);
    expect(
      result.diagnostics.map((d) => d.code),
      contains('INIT_ROLLBACK_FAILED'),
    );
    expect(
      await File('${root.path}/architecture.yaml').readAsString(),
      'replacement belongs to someone else',
    );
  });

  test(
    'dangling replacement remains an explicit residual after init failure',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'archway-dangling-residual-',
      );
      addTearDown(() => root.delete(recursive: true));
      final result = await runZoned(
        () => Bootstrap().initialize(root.path, 'mixed', false),
        zoneValues: {
          #archwayBootstrapFault: (String stage, String path) {
            if (stage == 'beforeCreate' && path == 'ARCHITECTURE.md') {
              File('${root.path}/architecture.yaml').deleteSync();
              Link('${root.path}/architecture.yaml').createSync('missing');
              throw const FileSystemException('Injected second create failure');
            }
          },
        },
      );
      expect(result.outcome, 'partial');
      expect(result.createdPaths, ['architecture.yaml']);
      expect(result.residualPaths, ['architecture.yaml']);
      expect(Link('${root.path}/architecture.yaml').targetSync(), 'missing');
    },
  );

  test(
    'dry-run cannot claim a plan for an inaccessible missing root',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'archway-missing-root-',
      );
      addTearDown(() => root.delete(recursive: true));
      await expectLater(
        Bootstrap().initialize('${root.path}/missing', 'dart', true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('all templates differ only in policy comments and share the full approved guide', () async {
    final root = await Directory.systemTemp.createTemp('archway-templates-');
    addTearDown(() => root.delete(recursive: true));
    final guides = <String>{};
    final policies = <String>{};
    for (final template in ['dart', 'typescript', 'mixed']) {
      final result = await Bootstrap().initialize(root.path, template, true);
      expect(result.outcome, 'planned');
      expect(result.plannedPaths, ['architecture.yaml', 'ARCHITECTURE.md']);
      expect(result.plannedFiles.map((f) => f.path), result.plannedPaths);
      expect(result.createdPaths, isEmpty);
      expect(result.residualPaths, isEmpty);
      expect(result.conflictingPaths, isEmpty);
      expect(await root.list().toList(), isEmpty);
      final policy = result.plannedFiles.first.content;
      expect(
        policy,
        contains(
          'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
        ),
      );
      expect(
        policy.split('\n').where((line) => !line.startsWith('#')).join('\n'),
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      policies.add(policy);
      final guide = result.plannedFiles.last.content;
      guides.add(guide);
      for (final phrase in [
        '--root ROOT',
        '--policy PATH',
        'before changing application code',
        'archway node ID',
        'archway owner PATH',
        'archway allows --paths FROM TO',
        'archway check',
        "application's own tests",
        'separate approval',
        'Never weaken policy',
        'AGENTS.md',
      ]) {
        expect(guide, contains(phrase));
      }
    }
    expect(policies, hasLength(3));
    expect(guides, hasLength(1));
  });

  test(
    'already removed created paths are not reported as residual files',
    () async {
      final runnerTemp = Platform.environment['RUNNER_TEMP'];
      final base = runnerTemp == null
          ? Directory.systemTemp
          : Directory(runnerTemp);
      final root = await base.createTemp('archway-disappeared-');
      print('BOOTSTRAP_RESIDUAL_TEST_ROOT=${root.path}');
      addTearDown(() => root.delete(recursive: true));
      final result = await runZoned(
        () => Bootstrap().initialize(root.path, 'mixed', false),
        zoneValues: {
          #archwayBootstrapFault: (String stage, String path) {
            if (stage == 'beforeCreate' && path == 'ARCHITECTURE.md') {
              File('${root.path}/architecture.yaml').deleteSync();
              throw FileSystemException('Injected second create failure', path);
            }
          },
        },
      );
      print(
        'BOOTSTRAP_RESIDUAL_COMPLETED outcome=${result.outcome} '
        'created=${result.createdPaths} residual=${result.residualPaths}',
      );
      expect(result.outcome, 'rolled_back');
      expect(result.createdPaths, ['architecture.yaml']);
      expect(result.residualPaths, isEmpty);
      expect(await root.list().toList(), isEmpty);
    },
  );
  test('directory close failure retains an operational outcome after file creation', () async {
    final root = await Directory.systemTemp.createTemp('archway-close-fail-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'dart', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'afterDispose')
            throw const FileSystemException('Injected directory close failure');
        },
      },
    );
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml', 'ARCHITECTURE.md']);
    expect(result.residualPaths, result.createdPaths);
  });
}
