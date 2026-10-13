import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/helper/validate_contract.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('contracts/helper/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;
dynamic _copy(Object? value) => jsonDecode(jsonEncode(value));

void _failed(Map a, Map b) {
  b['status'] = 'failed';
  b['tool_errors'] = [
    {
      'code': 'HELPER_ANALYSIS_FAILED',
      'message': 'Failure after verified source extraction',
      'path': null,
      'source_range': null,
    },
  ];
  b['files'][0]['coverage'] = 'partial';
}

void _unresolved(Map a, Map b) {
  b['status'] = 'incomplete';
  b['facts'][0]['resolution'] = {'kind': 'unresolved'};
  b['unknowns'] = [
    {
      'code': 'UNRESOLVED_IMPORT',
      'message': 'No target',
      'path': 'src/main.ts',
      'source_range': b['facts'][0]['source_range'],
    },
  ];
}

void main() {
  group('helper base', () {
    var count = 0;
    void scenario(
      String name,
      void Function(Map, Map) edit, {
      bool valid = false,
    }) {
      count++;
      test(name, () {
        final a = _fixture('valid-request');
        final b = _fixture('valid-response');
        edit(a, b);
        if (name == 'reversed-span' || name == 'zero-width-edge') {
          final range = b['facts'][0]['source_range'];
          expect(range['start']['line'], range['end']['line']);
          expect(
            range['end']['column'],
            name == 'reversed-span'
                ? lessThan(range['start']['column'])
                : range['start']['column'],
          );
        }
        expect(
          () => validateHelper(a, b),
          valid ? returnsNormally : throwsFormatException,
        );
      });
    }

    scenario('complete', (a, b) {}, valid: true);
    scenario('failed-with-verified-facts', _failed, valid: true);
    scenario('unresolved-incomplete', _unresolved, valid: true);
    scenario('wrong-version', (a, b) => b['protocol_version'] = 1);
    scenario('wrong-project', (a, b) => b['project_id'] = 'other');
    scenario('wrong-request', (a, b) => b['request_id'] = 'other');
    scenario('extra-policy-result', (a, b) => b['allowed'] = true);
    scenario('missing-file', (a, b) => b['files'] = []);
    scenario('duplicate-file', (a, b) => b['files'].add(_copy(b['files'][0])));
    scenario(
      'dangling-evidence',
      (a, b) => b['facts'][0]['input_ids'].add('missing'),
    );
    scenario('reversed-span', (a, b) {
      b['facts'][0]['source_range']['start']['column'] = 2;
      b['facts'][0]['source_range']['end']['column'] = 1;
    });
    scenario(
      'zero-based-span',
      (a, b) => b['facts'][0]['source_range']['start']['line'] = 0,
    );
    scenario(
      'parent-source-path',
      (a, b) => b['facts'][0]['source'] = '../outside.ts',
    );
    scenario(
      'unresolved-complete',
      (a, b) => b['facts'][0]['resolution'] = {'kind': 'unresolved'},
    );
    scenario(
      'partial-complete',
      (a, b) => b['files'][0]['coverage'] = 'partial',
    );
    scenario(
      'wrong-source-identity',
      (a, b) => b['inputs'][0]['observed_uri'] = 'file:///repo/other.ts',
    );
    scenario(
      'duplicate-input',
      (a, b) => b['inputs'].add(_copy(b['inputs'][0])),
    );
    scenario('failed-without-error', (a, b) => b['status'] = 'failed');
    scenario('missing-config-input', (a, b) => b['inputs'].removeLast());
    scenario('fact-from-failed-file', (a, b) {
      _failed(a, b);
      b['files'][0]['coverage'] = 'failed';
    });
    scenario('nonmember-complete-project', (a, b) {
      b['files'][0].addAll({
        'membership': 'nonmember',
        'coverage': 'not_applicable',
        'input_id': null,
      });
      b['facts'] = [];
    }, valid: true);
    scenario('unknown-membership-failed', (a, b) {
      _failed(a, b);
      b['files'][0].addAll({
        'membership': 'unknown',
        'coverage': 'failed',
        'input_id': null,
      });
      b['facts'] = [];
    }, valid: true);
    scenario('outside-local-target', (a, b) {
      b['facts'][0]['resolution'].addAll({
        'path': null,
        'canonical_file_uri': 'file:///outside/dep.ts',
      });
      b['inputs'][1].addAll({
        'observed_uri': 'file:///outside/dep.ts',
        'canonical_uri': 'file:///outside/dep.ts',
      });
    }, valid: true);
    scenario(
      'target-without-evidence',
      (a, b) => b['facts'][0]['resolution']['canonical_file_uri'] =
          'file:///other.ts',
    );
    scenario(
      'unknown-membership-complete',
      (a, b) => b['files'][0]['membership'] = 'unknown',
    );
    scenario(
      'drive-source-path',
      (a, b) => a['expected_files'] = ['C:/file.ts'],
    );
    scenario('trailing-slash-path', (a, b) => a['config_path'] = 'config/');
    scenario(
      'uri-remote-authority',
      (a, b) => a['root_uri'] = 'file://remote/repo',
    );
    scenario(
      'target-path-uri-mismatch',
      (a, b) => b['facts'][0]['resolution']['path'] = 'src/other.ts',
    );
    scenario(
      'observed-identity-conflict',
      (a, b) =>
          b['inputs'].add({...b['inputs'][0], 'id': 'ix', 'sha256': 'd' * 64}),
    );
    scenario(
      'source-canonical-outside-root',
      (a, b) => b['inputs'][0]['canonical_uri'] = 'file:///outside/main.ts',
    );
    scenario(
      'inside-target-null-path',
      (a, b) => b['facts'][0]['resolution']['path'] = null,
    );
    scenario('zero-width-diagnostic', (a, b) {
      _unresolved(a, b);
      b['unknowns'][0]['source_range'] = _copy(
        b['unknowns'][0]['source_range'],
      );
      b['unknowns'][0]['source_range']['end'] = _copy(
        b['unknowns'][0]['source_range']['start'],
      );
    }, valid: true);
    scenario(
      'zero-width-edge',
      (a, b) => b['facts'][0]['source_range']['end'] = _copy(
        b['facts'][0]['source_range']['start'],
      ),
    );
    scenario('filesystem-root-and-inventory', (a, b) {
      a['root_uri'] = 'file:///';
      for (final input in b['inputs']) {
        for (final key in ['observed_uri', 'canonical_uri']) {
          input[key] = input[key].replaceAll('file:///repo/', 'file:///');
        }
      }
      b['facts'][0]['resolution']['canonical_file_uri'] = 'file:///src/dep.ts';
      b['inputs'].add({
        'id': 'inventory-root',
        'kind': 'directory',
        'observed_uri': 'file:///',
        'canonical_uri': 'file:///',
        'sha256': 'e' * 64,
        'symlink_hops': [],
      });
    }, valid: true);
    scenario(
      'empty-file-uri',
      (a, b) => b['inputs'][0]['observed_uri'] = 'file:///',
    );
    test(
      'nonzero exit',
      () => expect(
        () => validateHelper(
          _fixture('valid-request'),
          _fixture('valid-response'),
          exitCode: 1,
        ),
        throwsFormatException,
      ),
    );
    assert(count == 36);
  });

  group('empty authoritative corpus', () {
    (Map<String, dynamic>, Map<String, dynamic>) empty() {
      final a = _fixture('valid-request')..['expected_files'] = [];
      final b = _fixture('valid-response');
      b['files'] = [];
      b['facts'] = [];
      b['inputs'] = [b['inputs'].last];
      return (a, b);
    }

    test('complete', () {
      final (a, b) = empty();
      expect(() => validateHelper(a, b), returnsNormally);
    });
    final rejected = <String, void Function(Map, Map)>{
      'missing corpus': (a, b) => a.remove('expected_files'),
      'null corpus': (a, b) => a['expected_files'] = null,
      'nonarray corpus': (a, b) => a['expected_files'] = '',
      'nonstring file': (a, b) => a['expected_files'] = [null],
      'malformed file': (a, b) => a['expected_files'] = ['../a.ts'],
      'duplicate file': (a, b) => a['expected_files'] = ['a.ts', 'a.ts'],
      'wrong request': (a, b) => b['request_id'] = 'other',
      'wrong project': (a, b) => b['project_id'] = 'other',
      'unexpected coverage': (a, b) =>
          b['files'] = _fixture('valid-response')['files'],
      'unexpected fact': (a, b) =>
          b['facts'] = _fixture('valid-response')['facts'],
      'missing config evidence': (a, b) => b['inputs'] = [],
    };
    for (final entry in rejected.entries) {
      test(entry.key, () {
        final (a, b) = empty();
        entry.value(a, b);
        expect(() => validateHelper(a, b), throwsFormatException);
      });
    }
  });

  group('helper semantic parity', () {
    for (final (name, path, encoded, valid) in [
      ('lone high surrogate', '\ud800', '%EF%BF%BD', false),
      ('lone low surrogate', '\udfff', '%EF%BF%BD', false),
      ('paired astral scalar', '\u{1f680}', '%F0%9F%9A%80', true),
      ('genuine replacement scalar', '\ufffd', '%EF%BF%BD', true),
    ]) {
      test('config path $name', () {
        final a = _fixture('valid-request')..['config_path'] = path;
        final b = _fixture('valid-response');
        for (final key in ['observed_uri', 'canonical_uri']) {
          b['inputs'].last[key] = 'file:///repo/$encoded';
        }
        expect(
          () => validateHelper(a, b),
          valid ? returnsNormally : throwsFormatException,
        );
      });
    }
    for (final (name, edit) in <(String, void Function(Map))>[
      ('missing physical identity', (input) => input['canonical_uri'] = null),
      (
        'malformed percent escape',
        (input) => input['observed_uri'] = 'file:///repo/%xx',
      ),
      ('encoded NUL', (input) => input['observed_uri'] = 'file:///repo/%00'),
    ]) {
      test(name, () {
        final b = _fixture('valid-response');
        final input = {
          ...b['inputs'][2],
          'id': 'extra',
          'observed_uri': 'file:///repo/extra',
        };
        edit(input);
        b['inputs'].add(input);
        expect(
          () => validateHelper(_fixture('valid-request'), b),
          throwsFormatException,
        );
      });
    }
    for (final sorted in [false, true]) {
      test('Unicode scalar corpus order sorted=$sorted', () {
        final a = _fixture('valid-request');
        final b = _fixture('valid-response');
        final paths = ['src/\ue000.ts', 'src/\u{10000}.ts'];
        a['expected_files'] = sorted ? paths : paths.reversed.toList();
        b['facts'] = [];
        b['files'] = [
          for (final path in a['expected_files'])
            {
              'path': path,
              'membership': 'nonmember',
              'coverage': 'not_applicable',
              'input_id': null,
            },
        ];
        expect(
          () => validateHelper(a, b),
          sorted ? returnsNormally : throwsFormatException,
        );
      });
    }
    test('integral JSON number positions', () {
      final b = _fixture('valid-response');
      b['facts'][0]['source_range']['start']['line'] = 1.0;
      expect(
        () => validateHelper(_fixture('valid-request'), b),
        returnsNormally,
      );
    });
  });
}
