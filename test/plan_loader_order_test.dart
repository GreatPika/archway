import 'dart:convert';
import 'dart:io';

import 'package:archway/src/plan/policy_definition.dart';
import 'package:archway/src/plan/policy_loader.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'closed root errors precede version, shape and semantic errors',
    () async {
      await expectInvalid(
        {
          ...policy(),
          'version': 2,
          'scope': [false],
          'unknown/key': true,
        },
        'POLICY_SCHEMA_INVALID',
        '/unknown~1key',
        'Unknown policy property.',
      );
      await expectInvalid(
        {
          ...policy(),
          'version': 2,
          'scope': [false],
        },
        'POLICY_VERSION_UNSUPPORTED',
        '/version',
        'Only policy version 1 is supported.',
      );
    },
  );

  test('duplicate IDs precede lexical path errors', () async {
    await expectInvalid(
      {
        ...policy(),
        'scope': ['../outside'],
        'nodes': [node('a'), node('a')],
      },
      'DUPLICATE_NODE_ID',
      '/nodes/1/id',
      'Duplicate ID a.',
    );
  });

  test(
    'missing contract warnings are discarded when a later path fails',
    () async {
      await expectInvalid(
        {
          ...policy(),
          'nodes': [
            {
              ...node('a'),
              'contracts': ['missing.md'],
              'public': ['../bad.dart'],
            },
          ],
        },
        'POLICY_PATH_INVALID',
        '/nodes/0/public/0',
        'Path escapes repository root.',
      );
    },
  );

  test(
    'unknown allows precede scope errors and suppress contract warnings',
    () async {
      await expectInvalid(
        {
          ...policy(),
          'scope': ['../outside'],
          'nodes': [
            {
              ...node('a'),
              'contracts': ['missing.md'],
              'allows': ['missing'],
            },
          ],
        },
        'UNKNOWN_NODE_ID',
        '/nodes/0/allows/0',
        'Unknown permission target missing.',
      );
    },
  );

  test(
    'scope path errors precede overlap and public ownership errors',
    () async {
      await expectInvalid(
        {
          ...policy(),
          'scope': ['../outside'],
          'nodes': [
            {
              ...node('a'),
              'owns': ['lib/'],
            },
            {
              ...node('b'),
              'owns': ['lib/'],
              'public': ['elsewhere.dart'],
            },
          ],
        },
        'POLICY_PATH_INVALID',
        '/scope/0',
        'Path escapes repository root.',
      );
    },
  );
}

Map<String, Object?> policy() => {
  'version': 1,
  'projects': [],
  'scope': ['./'],
  'exclude': [],
  'nodes': [],
};

Map<String, Object?> node(String id) => {
  'id': id,
  'responsibility': id,
  'owns': [],
  'public': [],
  'allows': [],
};

Future<void> expectInvalid(
  Map<String, Object?> source,
  String code,
  String pointer,
  String message,
) async {
  final root = await Directory.systemTemp.createTemp('archway-loader-order-');
  addTearDown(() => root.delete(recursive: true));
  final bytes = utf8.encode(jsonEncode(source));
  await File('${root.path}/architecture.yaml').writeAsBytes(bytes);
  final result = await loadPlan(RepositorySelection(root.path));
  expect(result.status, 'invalid_policy');
  expect(result.policyHash, 'sha256:${sha256.convert(bytes)}');
  expect(result.plan, isNull);
  final diagnostic = result.diagnostics.single;
  expect(diagnostic.code, code);
  expect(diagnostic.severity, 'error');
  expect(diagnostic.rulePointer, pointer);
  expect(diagnostic.message, message);
  expect(diagnostic.path, isNull);
}
