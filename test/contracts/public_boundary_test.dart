import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/compatibility/lexical_reference.dart' show normalize;
import '../../contracts/json/entrypoint_oracle.dart';

void main() {
  late Map policy;
  setUp(
    () => policy = jsonDecode(
      File('contracts/json/fixtures/policy-entrypoints.json')
          .readAsStringSync(),
    ),
  );
  group('PublicBoundary', () {
    test('test_nonlocal_resolution_not_subject_to_public', () {
      for (final kind in ['external', 'builtin', 'unresolved']) {
        expect(
          edgeViolation(policy, {
            'resolution': {'kind': kind},
          }),
          isNull,
          reason: kind,
        );
      }
    });
    test('test_target_classification_precedence', () {
      for (final (path, code) in [
        (null, 'LOCAL_TARGET_OUTSIDE_SCOPE'),
        ('docs/api.ts', 'LOCAL_TARGET_OUTSIDE_SCOPE'),
        ('src/pricing/generated/api.ts', 'LOCAL_TARGET_EXCLUDED'),
        ('src/free.ts', 'LOCAL_TARGET_UNOWNED'),
      ]) {
        expect(
          edgeViolation(policy, {
            'source': 'src/app/a.ts',
            'resolution': {'kind': 'local', 'path': path},
          }),
          code,
          reason: '$path',
        );
      }
    });
    test('test_unknown_source_preserves_target_classification', () {
      for (final (path, code) in [
        (null, 'LOCAL_TARGET_OUTSIDE_SCOPE'),
        ('src/pricing/generated/api.ts', 'LOCAL_TARGET_EXCLUDED'),
        ('src/free.ts', 'LOCAL_TARGET_UNOWNED'),
        ('src/pricing/internal.ts', null),
      ]) {
        expect(
          edgeViolation(policy, {
            'source': 'src/free-source.ts',
            'resolution': {'kind': 'local', 'path': path},
          }),
          code,
          reason: '$path',
        );
      }
    });
    test('test_same_owner_always', () {
      for (final public in [
        [],
        ['src/pricing/index.ts'],
      ]) {
        policy['nodes'][1]['public'] = public;
        expect(
          decide(policy, 'src/pricing/private.ts', 'src/pricing/other.ts'),
          ('allowed', 'same_owner'),
        );
      }
    });
    test('test_no_transitive_permission', () {
      policy['nodes'].add({
        'id': 'third',
        'responsibility': 'Third',
        'owns': ['src/third/'],
        'allows': [],
        'public': ['src/third/api.ts'],
      });
      policy['nodes'][1]['allows'] = ['third'];
      expect(decide(policy, 'src/app/a.ts', 'src/third/api.ts'), (
        'denied',
        'not_allowed',
      ));
    });
    test('test_lexical_normalization_and_exactness', () {
      policy['nodes'][1]['public'] = [
        r'src\pricing\index.ts',
        './src/pricing/a/../index.ts',
        'src/pricing/index.ts',
      ];
      validatePublic(policy);
      expect((policy['nodes'][1]['public'] as List).map(normalize).toSet(), {
        'src/pricing/index.ts',
      });
      expect(decide(policy, 'src/app/a.ts', 'src/pricing/index.ts'), (
        'allowed',
        'declared_allow',
      ));
      for (final target in [
        'src/pricing/index.ts/child',
        'src/pricing/Index.ts',
        'src/pricing/internal.ts',
      ]) {
        expect(decide(policy, 'src/app/a.ts', target), (
          'denied',
          'target_not_public',
        ), reason: target);
      }
    });
    test('test_path_query_usage', () {
      for (final path in [
        'src/pricing/',
        'src\\pricing\\',
        '.',
        'src/pricing/x.ts/.',
        'src/pricing/x.ts/a/..',
      ]) {
        for (final (source, target) in [
          (path, 'src/app/a.ts'),
          ('src/app/a.ts', path),
        ]) {
          expect(
            () => decide(policy, source, target),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'diagnostic',
                'USAGE_ERROR',
              ),
            ),
            reason: '$source -> $target',
          );
        }
      }
    });
    test('test_planned_mixed_language_and_data_files', () {
      for (final path in [
        'dart/lib/pricing.dart',
        'src/pricing/index.ts',
        'src/pricing/future.xyz',
        'src/pricing/API',
      ]) {
        policy['nodes'][1]['public'] = [path];
        validatePublic(policy);
        expect(decide(policy, 'src/app/a.ts', path), (
          'allowed',
          'declared_allow',
        ), reason: path);
      }
    });
    test('test_edge_kinds_are_uniform', () {
      for (final kind in [
        'import',
        'export',
        'import_type',
        'require',
        'dynamic_import',
        'part',
        'part_of',
      ]) {
        final edge = {
          'source': 'src/app/a.ts',
          'kind': kind,
          'resolution': {'kind': 'local', 'path': 'src/pricing/internal.ts'},
        };
        expect(edgeViolation(policy, edge), 'TARGET_NOT_PUBLIC', reason: kind);
        edge['source'] = 'src/pricing/index.ts';
        expect(edgeViolation(policy, edge), isNull, reason: kind);
      }
    });
    test('test_public_validation_diagnostics', () {
      for (final (raw, code) in [
        ('src/pricing/', 'PUBLIC_PATH_NOT_FILE'),
        ('src\\pricing\\', 'PUBLIC_PATH_NOT_FILE'),
        ('.', 'PUBLIC_PATH_NOT_FILE'),
        ('src/pricing/index.ts/.', 'PUBLIC_PATH_NOT_FILE'),
        ('src/pricing/index.ts/dir/..', 'PUBLIC_PATH_NOT_FILE'),
        ('src/pricing/generated/api.ts', 'PUBLIC_PATH_EXCLUDED'),
        ('docs/api.ts', 'PUBLIC_PATH_OUTSIDE_SCOPE'),
        ('src/app/main.ts', 'PUBLIC_PATH_NOT_OWNED'),
        ('src/unowned.ts', 'PUBLIC_PATH_NOT_OWNED'),
        ('../x', 'POLICY_PATH_INVALID'),
      ]) {
        policy['nodes'][1]['public'] = [raw];
        expect(
          () => validatePublic(policy),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'diagnostic',
              '$code: /nodes/1/public/0',
            ),
          ),
          reason: raw,
        );
      }
    });
    test('test_cross_owner_truth_table', () {
      for (final allowed in [false, true]) {
        for (final public in [false, true]) {
          policy['nodes'][0]['allows'] = allowed ? ['pricing'] : [];
          policy['nodes'][1]['public'] = public ? ['src/pricing/x.ts'] : [];
          final expected = !allowed
              ? ('denied', 'not_allowed')
              : public
              ? ('allowed', 'declared_allow')
              : ('denied', 'target_not_public');
          expect(
            decide(policy, 'src/app/main.ts', 'src/pricing/x.ts'),
            expected,
            reason: 'allowed=$allowed public=$public',
          );
          expect(
            decide(policy, 'app', 'pricing', mode: 'ids'),
            allowed ? ('allowed', 'declared_allow') : ('denied', 'not_allowed'),
          );
        }
      }
    });
  });
}
