import 'dart:io';
import 'dart:convert';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture, dartPolicy;

void main() {
  test('invalid policy stops inspection before compiler discovery', () async {
    final root = await Directory.systemTemp.createTemp('archway-inspection-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/architecture.yaml').writeAsString('version: 9');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'invalid_policy');
    expect(report.payload['policy_valid'], false);
    expect(report.payload['analysis_complete'], false);
    expect(report.payload['observed'], {
      'files': 0,
      'analyzed_files': 0,
      'edges': 0,
    });
    expect(report.payload['coverage'], {'files': [], 'projects': []});
    expect(report.toolVersions.values.every((v) => v == null), true);
  });
  test(
    'CLI check emits its complete report and status on stdout only',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-check-cli-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final stdout = StringBuffer(), stderr = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(stdout, stderr));
      expect(exit, 0);
      expect(stderr.toString(), '');
      expect(stdout.toString().split('\n'), hasLength(2));
      final output = jsonDecode(stdout.toString()) as Map;
      expect(output['command'], 'check');
      expect(output['status'], 'ok');
      expect(output['exit_code'], 0);
      expect(output['payload'], containsPair('analysis_complete', true));
      expect(
        (output['payload']['input_identity']['inputs'] as List).single['kind'],
        'policy',
      );
    },
  );

  test(
    'a known violation survives an unresolved import in an incomplete report',
    () async {
      final root = await dartFixture(
        main: "import '../core/private.dart';\nimport './missing.dart';\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 2,
      });
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      expect(
        (report.payload['unknowns'] as List).map((d) => d['code']),
        contains('UNRESOLVED_IMPORT'),
      );
      final inputs =
          (report.payload['input_identity'] as Map)['inputs'] as List;
      expect(
        inputs.any(
          (i) =>
              i['presence'] == 'absent' &&
              i['location']['path'] == 'lib/app/missing.dart',
        ),
        true,
      );
      expect(inputs.any((i) => i['kind'] == 'inventory'), true);
    },
  );

  test(
    'policy-excluded directory aliases do not create corpus failures',
    () async {
      final root = await dartFixture(
        policy: dartPolicy.replaceFirst(
          'exclude: []',
          'exclude: [lib/ignored/]',
        ),
      );
      await Link('${root.path}/lib/ignored').create('${root.path}/lib/core');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['unknowns'], isEmpty);
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
    },
  );

  test('a declared Dart project can prove its empty policy corpus', () async {
    final root = await dartFixture(
      policy: dartPolicy
          .replaceFirst('scope: [lib/]', 'scope: []')
          .replaceFirst('owns: [lib/app/]', 'owns: []')
          .replaceFirst('owns: [lib/core/]', 'owns: []'),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok');
    expect(report.payload['observed'], {
      'files': 0,
      'analyzed_files': 0,
      'edges': 0,
    });
    final projects = (report.payload['coverage'] as Map)['projects'] as List;
    expect(projects, hasLength(1));
    expect(projects.single['project_id'], 'app');
    expect(projects.single['adapter'], 'dart');
    expect(projects.single['status'], 'complete');
    expect(projects.single['files'], 0);
    expect(projects.single['analyzed_files'], 0);
    expect(projects.single['contexts'], isNotEmpty);
  });

  test(
    'an exact-file scope operand does not become a directory prefix',
    () async {
      final root = await dartFixture(
        policy: 'version: 1\nprojects: [{id: app, adapter: dart, package_roots: [./]}]\nscope: [lib]\nexclude: []\nnodes: []\n',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.payload['observed'], {
        'files': 0,
        'analyzed_files': 0,
        'edges': 0,
      });
    },
  );

  test(
    'an exact scope entry cannot hide a later directory-prefix entry',
    () async {
      final root = await dartFixture(
        policy: dartPolicy.replaceFirst('scope: [lib/]', 'scope: [lib, lib/]'),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
    },
  );

  test('two compiler memberships remain ambiguous rather than choosing the first project', () async {
    final root = await dartFixture(
      policy: dartPolicy.replaceFirst(
        'scope:',
        '  - id: other\n    adapter: dart\n    package_roots: [./]\nscope:',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    expect(
      rows.every(
        (f) =>
            f['assignment'] == 'ambiguous' &&
            f['project_id'] == null &&
            f['context_id'] == null,
      ),
      true,
    );
    expect((rows.first['candidates'] as List).map((c) => c['project_id']), [
      'app',
      'other',
    ]);
    expect((report.payload['facts'] as Map)['edges'], hasLength(2));
  });

  test('empty projects and nodes cannot hide existing scoped code', () async {
    final root = await dartFixture(
      policy:
          'version: 1\nprojects: []\nscope: [lib/]\nexclude: []\nnodes: []\n',
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(report.payload['observed'], {
      'files': 2,
      'analyzed_files': 0,
      'edges': 0,
    });
    expect((report.payload['violations'] as List).map((d) => d['code']), [
      'SOURCE_UNOWNED',
      'SOURCE_UNOWNED',
    ]);
    expect((report.payload['unknowns'] as List).map((d) => d['code']), [
      'ANALYSIS_CONTEXT_MISSING',
      'ANALYSIS_CONTEXT_MISSING',
    ]);
  });

  test(
    'target exclusion precedes module permission even for an unowned source',
    () async {
      final policy = dartPolicy
          .replaceFirst('exclude: []', 'exclude: [lib/core/]')
          .replaceFirst('owns: [lib/app/]', 'owns: []');
      final root = await dartFixture(policy: policy);
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(
        (report.payload['violations'] as List).map((d) => d['code']).toSet(),
        {'SOURCE_UNOWNED', 'LOCAL_TARGET_EXCLUDED'},
      );
      expect((report.payload['facts'] as Map)['edges'], hasLength(1));
    },
  );

  test(
    'a Dart directory alias retains canonical target boundary evidence',
    () async {
      final root = await dartFixture(
        main: "import '../alias/private.dart';\n",
        policy: dartPolicy.replaceFirst(
          'scope: [lib/]',
          'scope: [lib/app/, lib/core/]',
        ),
      );
      await Link('${root.path}/lib/alias').create('${root.path}/lib/core');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(
        (report.payload['violations'] as List).map((d) => d['code']),
        contains('DEPENDENCY_NOT_ALLOWED'),
      );
    },
  );

  test(
    'Inspection uses the same exact public-target predicate as Plan',
    () async {
      final privatePolicy = dartPolicy.replaceFirst(
        'allows: []',
        'allows: [core]',
      );
      final root = await dartFixture(policy: privatePolicy);
      final denied = await Inspection().check(RepositorySelection(root.path));
      final violation = (denied.payload['violations'] as List).single;
      expect(violation['code'], 'TARGET_NOT_PUBLIC');
      expect(violation['rule_pointer'], '/nodes/1/public');
      await File('${root.path}/architecture.yaml').writeAsString(
        privatePolicy.replaceFirst(
          'owns: [lib/core/]\n    allows: []\n    public: []',
          'owns: [lib/core/]\n    allows: []\n    public: [lib/core/private.dart]',
        ),
      );
      final allowed = await Inspection().check(RepositorySelection(root.path));
      expect(allowed.status, 'ok');
      expect(allowed.payload['violations'], isEmpty);
    },
  );
}
