import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/json/entrypoint_oracle.dart';
import '../../contracts/json/validate_contract.dart';
import '../../tool/validation/json_schema.dart';

void main() {
  final directory = Directory('contracts/json');
  final validators = {
    for (final name in ['public-result', 'export-diagnostics', 'policy'])
      name: ContractSchema(
        jsonDecode(
          File('${directory.path}/$name.schema.json').readAsStringSync(),
        ),
      ),
  };
  final index = jsonDecode(
    File('${directory.path}/fixture-index.json').readAsStringSync(),
  ) as List;
  test('export definitions are locally referenced and all reachable', () {
    final schema = jsonDecode(
      File('${directory.path}/export-diagnostics.schema.json')
          .readAsStringSync(),
    );
    verifyExportDefinitionReachability(schema);
    schema[r'$defs']['unused'] = {'type': 'string'};
    expect(
      () => verifyExportDefinitionReachability(schema),
      throwsFormatException,
    );
  });
  test('schema integer-valued numbers retain source-range semantic parity', () {
    final value = jsonDecode(
      File('contracts/json/fixtures/check-complete-fact.json')
          .readAsStringSync(),
    );
    final range = value['payload']['facts']['edges'][0]['source_range'];
    range['start']['line'] = 1.0;
    range['start']['column'] = (range['start']['column'] as num).toDouble();
    range['end']['line'] = (range['end']['line'] as num).toDouble();
    range['end']['column'] = (range['end']['column'] as num).toDouble();
    expect(validators['public-result']!.errors(value), isEmpty);
    expect(() => invariants(value), returnsNormally);
  });
  group('JSON contract fixtures', () {
    for (final row in index) {
      test(row['file'], () {
        final value = jsonDecode(
          File('${directory.path}/${row['file']}').readAsStringSync(),
        );
        final errors = validators[row['schema']]!.errors(value);
        Object? semantic;
        if (errors.isEmpty) {
          try {
            if (row['schema'] == 'policy') {
              validatePublic(value);
            } else {
              invariants(value);
            }
            if (row.containsKey('policy')) {
              verifyLinked(
                value,
                jsonDecode(
                  File('${directory.path}/${row['policy']}').readAsStringSync(),
                ),
              );
            }
          } on FormatException catch (error) {
            semantic = error;
          }
        }
        expect(
          errors.isEmpty && semantic == null,
          row['valid'],
          reason: 'schema errors: $errors; semantics: $semantic',
        );
      });
    }
  });
  test('rejects semantic catalogue arithmetic after schema validation', () {
    final value = jsonDecode(
      File('contracts/json/fixtures/node-catalogue.json').readAsStringSync(),
    );
    value['payload']['total'] += 1;
    final schema = ContractSchema(
      jsonDecode(
        File('contracts/json/public-result.schema.json').readAsStringSync(),
      ),
    );
    expect(schema.errors(value), isEmpty);
    expect(() => invariants(value), throwsFormatException);
  });
}
