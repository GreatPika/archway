import 'dart:convert';
import 'dart:io';

import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'restricted YAML rejects syntax constructs before shape validation',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-yaml-');
      addTearDown(() => root.delete(recursive: true));
      const empty =
          'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n';
      for (final source in [
        '$empty---\n$empty',
        '${empty}version: 1\n',
        'version: 1\nprojects: [{id: a, id: b}]\nscope: []\nexclude: []\nnodes: []\n',
        '${empty}1: ignored\n',
        '${empty}extra: {false: ignored}\n',
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: [{id: app, 42: wrong}]\n',
        '${empty}extra: {<<: ignored}\n',
        '${empty}extra: .nan\n',
        '${empty}extra: .inf\n',
        '${empty}extra: -.Inf\n',
        'version: 1\nprojects: &empty []\nscope: *empty\nexclude: []\nnodes: []\n',
        '${empty}extra: &value plain\n',
        '${empty}extra: &value []\n',
        '${empty}extra: &value {}\n',
        '${empty}extra: *missing\n',
        '${empty}extra: !example hello\n',
        '%YAML 1.1\n---\n$empty',
        '%TAG !c! \n---\n$empty',
        '%TAG !! tag:yaml.org,2002:\n$empty',
        '%TAG !! tag:yaml.org,2002:\n%TAG !! tag:yaml.org,2002:\n---\n$empty',
        '%TAG !e! tag:example.test,2026:\n---\n$empty',
      ]) {
        await File('${root.path}/architecture.yaml').writeAsString(source);
        final result = await Plan.load(RepositorySelection(root.path));
        expect(result.status, 'invalid_policy', reason: source);
        expect(result.plan, isNull);
        expect(result.policyHash, isNotNull);
        expect(
          result.diagnostics.single.code,
          'POLICY_PARSE_ERROR',
          reason: source,
        );
      }
      await File('${root.path}/architecture.yaml').writeAsBytes([0xff, 0xfe]);
      final invalidUtf8 = await Plan.load(RepositorySelection(root.path));
      expect(invalidUtf8.diagnostics.single.code, 'POLICY_PARSE_ERROR');
    },
  );
  test('closed policy shapes never coerce scalar types', () async {
    final root = await Directory.systemTemp.createTemp('archway-shape-');
    addTearDown(() => root.delete(recursive: true));
    final cases = <(Map<String, Object?>, String)>[
      ({'version': '1'}, '/version'),
      ({'version': 1.0}, '/version'),
      ({'scope': 'src/'}, '/scope'),
      (
        {
          'exclude': [false],
        },
        '/exclude/0',
      ),
      ({'nodes': {}}, '/nodes'),
      ({'extra': true}, '/extra'),
      (
        {
          'projects': [42],
        },
        '/projects/0',
      ),
      (
        {
          'projects': [
            {'id': 'a', 'adapter': 'rust'},
          ],
        },
        '/projects/0/adapter',
      ),
      (
        {
          'projects': [
            {'id': 'a', 'adapter': 'typescript', 'tsconfig': 1},
          ],
        },
        '/projects/0/tsconfig',
      ),
      (
        {
          'projects': [
            {'id': 'a', 'adapter': 'dart', 'package_roots': []},
          ],
        },
        '/projects/0/package_roots',
      ),
      (
        {
          'nodes': [
            {'id': 'a', 'responsibility': 'A', 'owns': [], 'allows': []},
          ],
        },
        '/nodes/0/public',
      ),
      (
        {
          'nodes': [
            {
              'id': 'a',
              'responsibility': false,
              'owns': [],
              'public': [],
              'allows': [],
            },
          ],
        },
        '/nodes/0/responsibility',
      ),
      (
        {
          'nodes': [
            {
              'id': 'a\n',
              'responsibility': 'A',
              'owns': [],
              'public': [],
              'allows': [],
            },
          ],
        },
        '/nodes/0/id',
      ),
      (
        {
          'nodes': [
            {
              'id': 'a',
              'responsibility': 'A',
              'owns': [],
              'public': [],
              'allows': [],
              'contracts': [1],
            },
          ],
        },
        '/nodes/0/contracts/0',
      ),
    ];
    for (final (changes, pointer) in cases) {
      await File('${root.path}/architecture.yaml').writeAsString(
        jsonEncode({
          'version': 1,
          'projects': [],
          'scope': [],
          'exclude': [],
          'nodes': [],
          ...changes,
        }),
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy', reason: changes.toString());
      expect(result.diagnostics.single.code, 'POLICY_SCHEMA_INVALID');
      expect(result.diagnostics.single.rulePointer, pointer);
    }
  });

  test(
    'portable lexical paths preserve exact-prefix case and NFC semantics',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-lexical-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/architecture.yaml');
      final policy = <String, Object?>{
        'version': 1,
        'projects': [],
        'scope': ['./'],
        'exclude': [],
        'nodes': [
          {
            'id': 'all',
            'responsibility': 'Everything',
            'owns': ['./'],
            'public': [],
            'allows': [],
          },
        ],
      };
      await file.writeAsString(jsonEncode(policy));
      final plan = (await Plan.load(RepositorySelection(root.path))).plan!;
      for (final entry in {
        r'src\a.ts': 'src/a.ts',
        './src//x/../a.ts': 'src/a.ts',
        'a/..': './',
        '.': './',
        './': './',
        'src/': 'src/',
        'src': 'src',
        'src/%2e%2e/a.ts': 'src/%2e%2e/a.ts',
        'src/e\u0301.ts': 'src/é.ts',
        'a/../b': 'b',
        r'a\b\': 'a/b/',
        'src/A.ts': 'src/A.ts',
      }.entries) {
        expect(plan.owner(entry.key).path, entry.value);
        expect(plan.owner(entry.key).ownerId, 'all');
      }
      for (final invalid in [
        '',
        '../repo/a.ts',
        'a/../../b',
        '/src/a',
        r'C:\a',
        'C:a',
        r'\\server\share\x',
        r'\\?\C:\x',
        'src/CON.ts',
        'src/lpt1',
        'src/a.ts:secret',
        'a/evil.',
        'a/b ',
        'a/\u0000b',
        'a/\u007fb',
        'a/*.ts',
        'https://a/b',
        'src/[a].ts',
        'src/{a}.ts',
      ]) {
        expect(
          () => plan.owner(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    },
  );

  test(
    'ordinary quoted and block scalars remain YAML strings without coercion',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-yaml-valid-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString(
        '%YAML 1.2\n---\nversion: 1 # comment\nprojects: []\nscope: [src/]\nexclude: []\nnodes:\n'
        '  - id: yes\n    responsibility: |\n      Keep exact text.\n    owns: ["src/"]\n    public: [\'src/future\']\n    allows: []\n',
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'ok');
      expect(result.plan!.node('yes')!['responsibility'], 'Keep exact text.\n');
      expect(result.plan!.node('yes')!['public'], ['src/future']);
      expect(await root.list().length, 1);
    },
  );
  test('standard YAML tags retain parser types without application coercion', () async {
    final root = await Directory.systemTemp.createTemp('archway-core-tags-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/architecture.yaml');
    await file.writeAsString(
      '!!map\nversion: !!int 1\nprojects: !!seq []\nscope: []\nexclude: []\nnodes:\n'
      '  - id: app\n    responsibility: !!str 123\n    owns: []\n    public: []\n    allows: []\n',
    );
    final valid = await Plan.load(RepositorySelection(root.path));
    expect(valid.status, 'ok');
    expect(valid.plan!.node('app')!['responsibility'], '123');
    await file.writeAsString(
      'version: !!str 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
    );
    final invalid = await Plan.load(RepositorySelection(root.path));
    expect(invalid.status, 'invalid_policy');
    expect(invalid.diagnostics.single.code, 'POLICY_SCHEMA_INVALID');
    expect(invalid.diagnostics.single.rulePointer, '/version');
    for (final (prefix, tag) in [
      ('%TAG !! tag:yaml.org,2002:\n---\n', '!!int'),
      ('%TAG !core! tag:yaml.org,2002:\n---\n', '!core!int'),
      ('', '!<tag:yaml.org,2002:int>'),
      ('%TAG ! tag:yaml.org,2002:\n---\n', '!int'),
      ('%TAG !core! tag:yaml.org,2002:i\n---\n', '!core!nt'),
    ]) {
      await file.writeAsString(
        '${prefix}version: $tag 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      expect(
        (await Plan.load(RepositorySelection(root.path))).status,
        'ok',
        reason: tag,
      );
    }
  });
  test('verbatim tag compatibility leaves quoted text and comments unchanged', () async {
    final root = await Directory.systemTemp.createTemp('archway-tag-text-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/architecture.yaml').writeAsString(
      '# !<tag:yaml.org,2002:int> malformed comment text\nversion: !<tag:yaml.org,2002:int> 1\nprojects: []\nscope: []\nexclude: []\nnodes:\n'
      '  - id: app\n    responsibility: "!<tag:yaml.org,2002:str> stays literal"\n    owns: []\n    public: []\n    allows: []\n',
    );
    final result = await Plan.load(RepositorySelection(root.path));
    expect(result.status, 'ok');
    expect(
      result.policyHash,
      'sha256:0765490dc1fb311a1aaf9d836a3a29e936192532723a8d7dc2c337001c33f2c0',
    );
    expect(
      result.plan!.node('app')!['responsibility'],
      '!<tag:yaml.org,2002:str> stays literal',
    );
  });
  test('tag compatibility rejects empty shorthand suffixes and invalid handles', () async {
    final root = await Directory.systemTemp.createTemp('archway-tag-grammar-');
    addTearDown(() => root.delete(recursive: true));
    for (final (handle, suffix, tag) in [
      ('!c!', 'int', '!c!'),
      ('!c.d!', '', '!c.d!int'),
      ('!c/d!', '', '!c/d!int'),
      ('!c_d!', '', '!c_d!int'),
    ]) {
      await File('${root.path}/architecture.yaml').writeAsString(
        '%TAG $handle tag:yaml.org,2002:$suffix\n---\nversion: $tag 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy', reason: tag);
      expect(result.diagnostics.single.code, 'POLICY_PARSE_ERROR');
    }
  });
  test('tagged numeric loader boundaries retain types and return diagnostics', () async {
    final root = await Directory.systemTemp.createTemp('archway-tag-numbers-');
    addTearDown(() => root.delete(recursive: true));
    for (final value in [
      '1',
      '0',
      '-1',
      '01',
      '1.0',
      '1e3',
      '"1"',
      "'0'",
      '|-\n  1',
      '>-\n  0',
    ]) {
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: !!float $value\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy', reason: value);
      expect(
        result.diagnostics.single.code,
        'POLICY_SCHEMA_INVALID',
        reason: value,
      );
      expect(result.diagnostics.single.rulePointer, '/version');
    }
    for (final value in [
      '!!float ~',
      '!!float ""',
      '!!int ""',
      '!!float .nan',
    ]) {
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: $value\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy', reason: value);
      expect(
        result.diagnostics.single.code,
        'POLICY_PARSE_ERROR',
        reason: value,
      );
      expect(result.policyHash, isNotNull);
    }
  });
}
