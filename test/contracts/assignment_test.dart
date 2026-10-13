import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../contracts/assignment/assignment_reference.dart';

void main() {
  final fixtures = jsonDecode(
    File('contracts/assignment/fixtures.json').readAsStringSync(),
  ) as List;
  test('every observed input remains in coverage', () {
    final coverage = [
      for (final fixture in fixtures)
        {
          'path': fixture['path'],
          'fixture': fixture['id'],
          'assignment': assign(fixture),
        },
    ];
    expect(coverage, hasLength(fixtures.length));
    expect(
      coverage.map((item) => item['fixture']).toSet(),
      fixtures.map((fixture) => fixture['id']).toSet(),
    );
  });
  test('Dart context descriptor canonical UTF-8 and SHA-256 fixture', () {
    final context = jsonDecode(
      File('contracts/assignment/context-id-fixture.json').readAsStringSync(),
    );
    final descriptor = context['descriptor'] as Map;
    final keys = descriptor.keys.cast<String>().toList()..sort();
    final encoded = utf8.encode(
      jsonEncode({for (final key in keys) key: descriptor[key]}),
    );
    expect(utf8.decode(encoded), context['canonical_descriptor_utf8']);
    expect(sha256.convert(encoded).toString(), context['descriptor_sha256']);
    expect(
      context['context_id'],
      'dart:${context['project_id']}:${context['descriptor_sha256']}',
    );
    expect(descriptor.keys.toSet(), {
      'root',
      'included_paths',
      'excluded_paths',
      'package_config_path',
      'options_paths',
      'sdk_version',
    });
    for (final field in ['included_paths', 'excluded_paths', 'options_paths']) {
      final values = (descriptor[field] as List).cast<String>();
      expect(values, values.toSet().toList()..sort(), reason: field);
    }
  });
  test('26 decision fixtures retain ordering and duplicate invariance', () {
    expect(fixtures, hasLength(26));
    for (final fixture in fixtures) {
      final actual = assign(fixture);
      expect(actual, fixture['expected_assignment'], reason: fixture['id']);
      final candidates = fixture['candidates'] as List;
      expect(
        assign({...fixture, 'candidates': candidates.reversed.toList()}),
        actual,
        reason: '${fixture['id']}: ordering',
      );
      expect(
        assign({
          ...fixture,
          'candidates': [...candidates, ...candidates],
        }),
        actual,
        reason: '${fixture['id']}: duplicates',
      );
      if (actual == 'assigned') {
        expect({
          for (final candidate in candidates)
            (candidate['project_id'], candidate['context_id']),
        }, hasLength(1));
      }
    }
  });
}
