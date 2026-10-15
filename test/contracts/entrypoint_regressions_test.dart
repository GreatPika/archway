import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/json/entrypoint_oracle.dart' as oracle;
import '../../contracts/json/validate_contract.dart';
import '../../tool/validation/json_schema.dart';

Map _fixture(String name) =>
    jsonDecode(File('contracts/json/fixtures/$name').readAsStringSync());
Map _copy(Map value) => jsonDecode(jsonEncode(value));

void main() {
  final seed = _fixture('policy-entrypoints.json');
  final policySchema = ContractSchema(
    jsonDecode(File('contracts/json/policy.schema.json').readAsStringSync()),
  );
  final resultSchema = ContractSchema(
    jsonDecode(
      File('contracts/json/public-result.schema.json').readAsStringSync(),
    ),
  );
  void publicCase(String name, Object? public, bool expected) {
    test(name, () {
      final policy = _copy(seed);
      policy['nodes'][1]['public'] = public;
      var accepted = policySchema.errors(policy).isEmpty;
      if (accepted) {
        try {
          oracle.validatePublic(policy);
        } on FormatException {
          accepted = false;
        }
      }
      expect(accepted, expected);
    });
  }

  void decision(
    String name,
    String source,
    String target,
    Object expected, {
    Map? policy,
    String mode = 'paths',
  }) {
    final selected = _copy(policy ?? seed);
    test(name, () {
      Object actual;
      try {
        final value = oracle.decide(selected, source, target, mode: mode);
        actual = [value.$1, value.$2];
      } on FormatException {
        actual = 'invalid';
      }
      expect(actual, expected);
    });
  }

  void linked(String name, Map result, Map policy, bool expected) {
    final input = _copy(result), selected = _copy(policy);
    test(name, () {
      var accepted = resultSchema.errors(input).isEmpty;
      if (accepted) {
        try {
          invariants(input);
          oracle.verifyLinked(input, selected);
        } on FormatException {
          accepted = false;
        }
      }
      expect(accepted, expected);
    });
  }

  void record(String name, Object? Function() actual, Object? expected) {
    test(name, () => expect(actual(), expected));
  }

  for (final (name, value) in <(String, Object?)>[
    ('None', null),
    ('{}', {}),
    ("'src/pricing/index.ts'", 'src/pricing/index.ts'),
    ('5', 5),
    ('False', false),
    ('[None]', [null]),
    ('[3]', [3]),
    ('[{}]', [{}]),
  ]) {
    publicCase('malformed-public-$name', value, false);
  }
  record('required-public', () {
    final policy = _copy(seed);
    policy['nodes'][1].remove('public');
    return policySchema.errors(policy).isEmpty;
  }, false);
  for (final raw in [
    '.',
    './',
    'src/pricing/',
    'src/pricing\\',
    'src/pricing/.',
    'src/pricing/x/..',
    'src/pricing/x/../',
    'src/pricing/*.ts',
    '/src/pricing/index.ts',
    '../index.ts',
    'src/app/main.ts',
    'src/pricing/generated/api.ts',
    'other/index.ts',
    'src/unowned.ts',
  ]) {
    publicCase('public-invalid-$raw', [raw], false);
  }
  for (final raw in [
    'src/pricing/future.ts',
    'src/pricing/extensionless',
    'src/pricing/./index.ts',
    'src/pricing/x/../index.ts',
    r'src\pricing\index.ts',
    'src/pricing/e\u0301.ts',
  ]) {
    publicCase('public-valid-$raw', [raw], true);
  }
  publicCase('duplicate-normalized-public', [
    'src/pricing/index.ts',
    'src/pricing/./index.ts',
  ], true);
  publicCase('exact-prefix-files-not-subsumed', [
    'src/pricing/api',
    'src/pricing/api.ts',
  ], true);
  for (final raw in ['./', 'src/pricing/x/../']) {
    decision('query-directory-target-$raw', 'src/app/main.ts', raw, 'invalid');
    decision(
      'query-directory-source-$raw',
      raw,
      'src/pricing/index.ts',
      'invalid',
    );
  }
  decision(
    'excluded-target',
    'src/app/main.ts',
    'src/pricing/generated/api.ts',
    ['undetermined', 'ownership_unknown'],
  );
  decision('unowned-source', 'src/orphan.ts', 'src/pricing/index.ts', [
    'undetermined',
    'ownership_unknown',
  ]);
  decision('outside-target', 'src/app/main.ts', 'outside.ts', [
    'undetermined',
    'ownership_unknown',
  ]);
  var policy = _copy(seed);
  policy['nodes'][1]['public'] = ['src/pricing/source.ts'];
  decision(
    'redirect-to-private-dts-source-public-insufficient',
    'src/app/main.ts',
    'src/pricing/source.d.ts',
    ['denied', 'target_not_public'],
    policy: policy,
  );
  policy['nodes'][1]['public'].add('src/pricing/source.d.ts');
  decision(
    'redirect-to-public-dts',
    'src/app/main.ts',
    'src/pricing/source.d.ts',
    ['allowed', 'declared_allow'],
    policy: policy,
  );
  policy = _copy(seed);
  policy['nodes'].add({
    'id': 'core',
    'responsibility': 'Core',
    'owns': ['src/core/'],
    'allows': [],
    'public': ['src/core/index.ts'],
  });
  policy['nodes'][1]['allows'] = ['core'];
  for (final (name, source, target, expected) in [
    (
      'facade-B-to-C',
      'src/pricing/index.ts',
      'src/core/index.ts',
      ['allowed', 'declared_allow'],
    ),
    (
      'facade-B-direct-C-private',
      'src/pricing/index.ts',
      'src/core/private.ts',
      ['denied', 'target_not_public'],
    ),
  ]) {
    decision(name, source, target, expected, policy: policy);
  }

  var value = _fixture('allows-public-entrypoint.json');
  policy = _copy(seed);
  policy['nodes'][1]['public'] = [];
  linked('mutated-public-cannot-preserve-allowed-query', value, policy, false);
  policy = _copy(seed);
  policy['nodes'][0]['allows'] = [];
  linked('mutated-allows-cannot-preserve-allowed-query', value, policy, false);
  value = _fixture('allows-public-entrypoint.json');
  value['payload']['reason'] = 'same_owner';
  linked('file-query-false-same-owner-reason', value, seed, false);
  value = _fixture('check-public-import.json');
  policy = _copy(seed);
  policy['nodes'][1]['public'] = [];
  linked(
    'mutated-public-cannot-preserve-successful-check',
    value,
    policy,
    false,
  );
  value = _fixture('check-public-import.json');
  value['payload']['facts']['edges'][0]['resolution']['path'] =
      'src/pricing/private.d.ts';
  value['payload']['facts']['edges'][0]['resolution']['canonical_file_uri'] =
      'file:///repo/src/pricing/private.d.ts';
  linked(
    'redirected-private-dts-cannot-preserve-successful-check',
    value,
    seed,
    false,
  );
  decision(
    'dart-physical-source-cross-owner',
    'dart/lib/pricing/part.dart',
    'src/app/main.ts',
    ['denied', 'not_allowed'],
  );
  decision(
    'dart-public-library-same-owner-private-part',
    'dart/lib/pricing.dart',
    'dart/lib/pricing/part.dart',
    ['allowed', 'same_owner'],
  );
  // Classification is trusted adapter evidence, never inferred from spelling.
  record(
    'bare-package-spelling-cannot-bypass-confirmed-local',
    () => oracle.edgeViolation(seed, {
      'source': 'src/app/main.ts',
      'specifier': 'pricing/internal',
      'resolution': {'kind': 'local', 'path': 'src/pricing/internal.ts'},
    }),
    'TARGET_NOT_PUBLIC',
  );
  for (final kind in ['external', 'builtin']) {
    record(
      'proven-$kind-outside-public-rule',
      () => oracle.edgeViolation(seed, {
        'source': 'src/app/main.ts',
        'resolution': {'kind': kind, 'identity': 'verified:example'},
      }),
      null,
    );
  }
  value = _fixture('check-private-import.json');
  value['payload']['violations'][0]['source_range']['start']['column'] = 2;
  linked('private-diagnostic-mutated-source-span', value, seed, false);
  value = _fixture('check-private-import.json');
  value['payload']['violations'].add(_copy(value['payload']['violations'][0]));
  linked('private-diagnostic-duplicated', value, seed, false);
  value = _fixture('check-private-import.json');
  value['payload']['violations'][0]['code'] = 'DEPENDENCY_NOT_ALLOWED';
  linked('private-diagnostic-wrong-principal-failure', value, seed, false);
  for (final (target, expected) in [
    ('src/pricing/generated/x.ts', 'LOCAL_TARGET_EXCLUDED'),
    ('outside/x.ts', 'LOCAL_TARGET_OUTSIDE_SCOPE'),
    ('src/orphan.ts', 'LOCAL_TARGET_UNOWNED'),
  ]) {
    record(
      'target-classification-survives-unowned-source-$target',
      () => oracle.edgeViolation(seed, {
        'source': 'src/missing-owner.ts',
        'resolution': {'kind': 'local', 'path': target},
      }),
      expected,
    );
  }
}
