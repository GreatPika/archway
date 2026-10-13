import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/validation/json_schema.dart';

void main() {
  test('fails closed on empty enums at root and nested schema positions', () {
    for (final schema in [
      {'enum': []},
      {
        'properties': {
          'value': {'enum': []},
        },
      },
      {
        'items': {
          'anyOf': [
            {'enum': []},
          ],
        },
      },
    ]) {
      expect(() => ContractSchema(schema), throwsA(isA<FormatException>()));
    }
  });

  test('does not mistake constant instance data for a nested schema', () {
    final schema = ContractSchema({
      'const': {'enum': []},
    });
    expect(schema.errors({'enum': []}), isEmpty);
    expect(
      schema.errors({
        'enum': [1],
      }),
      isNotEmpty,
    );
  });
  test('rejects unsupported remote references without fetching them', () {
    expect(
      () => ContractSchema({r'$ref': 'https://example.invalid/schema.json'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepts boolean schemas', () {
    expect(ContractSchema(true).errors(null), isEmpty);
    expect(ContractSchema(false).errors(null), isNotEmpty);
  });

  final malformed = <String, Object?>{
    'unknown type': {'type': 'nonsense'},
    'repeated required name': {
      'required': ['x', 'x'],
    },
    'string minimum': {'minimum': '3'},
    'negative minLength': {'minLength': -1},
    'fractional minItems': {'minItems': 1.5},
    'nonboolean uniqueItems': {'uniqueItems': 1},
    'empty allOf': {'allOf': []},
    'invalid regular expression': {'pattern': '['},
    'non-schema property': {
      'properties': {'x': 3},
    },
    'array items': {'items': []},
    'non-schema conditional': {'if': 3},
    'non-schema definition': {
      r'$defs': {'bad': 3},
    },
    'empty type': {'type': []},
    'repeated type': {
      'type': ['string', 'string'],
    },
    'nonstring required name': {
      'required': [2],
    },
    'nonstring reference': {r'$ref': 2},
    'non-schema additionalProperties': {'additionalProperties': 3},
    'non-schema contains': {'contains': 3},
    'negative maxItems': {'maxItems': -1},
    'nested property': {
      'properties': {
        'x': {
          'required': ['x', 'x'],
        },
      },
    },
    'nested definition': {
      r'$defs': {
        'x': {'type': []},
      },
    },
    'nested conditional': {
      'if': true,
      'then': {'minItems': -1},
    },
    'nested alternative': {
      'items': {
        'anyOf': [
          {
            'required': [2],
          },
        ],
      },
    },
    'null document': null,
  };
  for (final entry in malformed.entries) {
    test('rejects malformed schema: ${entry.key}', () {
      expect(() => ContractSchema(entry.value), throwsA(anything));
    });
  }

  for (final path in [
    'contracts/json/public-result.schema.json',
    'contracts/json/export-diagnostics.schema.json',
    'contracts/json/policy.schema.json',
    'contracts/helper/request.schema.json',
    'contracts/helper/response.schema.json',
  ]) {
    test('meta-validates the owned schema $path', () {
      expect(
        () => ContractSchema(jsonDecode(File(path).readAsStringSync())),
        returnsNormally,
      );
    });
  }
  test('rejects malformed schema definitions before validating instances', () {
    expect(
      () => ContractSchema({
        'required': ['x', 'x'],
      }),
      throwsA(isA<FormatException>()),
    );
  });
  test('validates an instance against a local Draft 2020-12 definition', () {
    final schema = ContractSchema({
      r'$schema': 'https://json-schema.org/draft/2020-12/schema',
      r'$defs': {
        'value': {'type': 'integer'},
      },
      r'$ref': r'#/$defs/value',
    });
    expect(schema.errors(3), isEmpty);
    expect(schema.errors('3'), isNotEmpty);
  });
}
