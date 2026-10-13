import 'dart:async';
import 'dart:io';

import 'package:archway/src/bootstrap/bootstrap.dart';
import 'package:test/test.dart';

void main() {
  test('dry-run previews both complete files without writes', () async {
    final root = await Directory.systemTemp.createTemp('archway-init-');
    addTearDown(() => root.delete(recursive: true));
    final result = await Bootstrap().initialize(root.path, 'dart', true);
    expect(result.outcome, 'planned');
    expect(result.plannedPaths, ['architecture.yaml', 'ARCHITECTURE_AGENT.md']);
    expect(result.plannedFiles.map((f) => f.path), result.plannedPaths);
    expect(
      result.plannedFiles.first.content,
      contains('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n'),
    );
    expect(result.plannedFiles.last.content, contains('archway check'));
    expect(result.createdPaths, isEmpty);
    expect(result.residualPaths, isEmpty);
    expect(result.conflictingPaths, isEmpty);
    expect(await root.list().toList(), isEmpty);
  });
  test(
    'dry-run reports every preflight conflict without altering targets',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-conflict-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString('keep policy');
      await Directory('${root.path}/ARCHITECTURE_AGENT.md').create();
      final result = await Bootstrap().initialize(root.path, 'mixed', true);
      expect(result.outcome, 'conflict');
      expect(result.conflictingPaths, [
        'architecture.yaml',
        'ARCHITECTURE_AGENT.md',
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
        'ARCHITECTURE_AGENT.md',
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
          if (stage == 'beforeWrite' && path == 'ARCHITECTURE_AGENT.md')
            throw FileSystemException('Injected write failure', path);
        },
      },
    );
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml', 'ARCHITECTURE_AGENT.md']);
    expect(result.residualPaths, result.createdPaths);
    expect(
      result.diagnostics.map((d) => d.code),
      containsAll(['INIT_WRITE_FAILED', 'INIT_ROLLBACK_FAILED']),
    );
    expect(
      await File('${root.path}/architecture.yaml').readAsString(),
      contains('version: 1'),
    );
    expect(await File('${root.path}/ARCHITECTURE_AGENT.md').length(), 0);
  });

  test('exclusive-create race keeps the other writer file and reports its conflict', () async {
    final root = await Directory.systemTemp.createTemp('archway-race-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'mixed', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforeCreate' && path == 'ARCHITECTURE_AGENT.md')
            File('${root.path}/$path').writeAsStringSync('other writer');
        },
      },
    );
    expect(result.outcome, 'partial');
    expect(result.createdPaths, ['architecture.yaml']);
    expect(result.residualPaths, ['architecture.yaml']);
    expect(result.conflictingPaths, ['ARCHITECTURE_AGENT.md']);
    expect(
      await File('${root.path}/ARCHITECTURE_AGENT.md').readAsString(),
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
          if (stage == 'beforeCreate' && path == 'ARCHITECTURE_AGENT.md') {
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
            if (stage == 'beforeCreate' && path == 'ARCHITECTURE_AGENT.md') {
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
      final policy = result.plannedFiles.first.content;
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
    expect(await root.list().toList(), isEmpty);
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
            if (stage == 'beforeCreate' && path == 'ARCHITECTURE_AGENT.md') {
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
  test('write errors identify the actual contractual target even without an OS path', () async {
    final root = await Directory.systemTemp.createTemp('archway-fault-path-');
    addTearDown(() => root.delete(recursive: true));
    final result = await runZoned(
      () => Bootstrap().initialize(root.path, 'dart', false),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforeWrite')
            throw const FileSystemException('Injected write failure');
        },
      },
    );
    expect(result.diagnostics.first.path, 'architecture.yaml');
  });

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
    expect(result.createdPaths, ['architecture.yaml', 'ARCHITECTURE_AGENT.md']);
    expect(result.residualPaths, result.createdPaths);
  });
}
