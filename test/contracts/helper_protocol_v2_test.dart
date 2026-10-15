import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/helper/validate_contract.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('contracts/helper/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('helper protocol v2', () {
    const hop = {'observed_uri': 'file:///repo/link', 'target': './src'};
    void hops(Map response, Object? value) {
      response['inputs'][1]['observed_uri'] = 'file:///repo/link/dep.ts';
      response['facts'][0]['resolution']['via_path'] =
          'file:///repo/link/dep.ts';
      response['inputs'][1]['symlink_hops'] = value;
    }

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
        b['inputs'].addAll([
          {
            'id': 'directory',
            'kind': 'directory',
            'observed_uri': 'file:///repo/src',
            'canonical_uri': 'file:///repo/src',
            'sha256': 'e' * 64,
            'symlink_hops': [],
          },
          {
            'id': 'missing',
            'kind': 'absent',
            'observed_uri': 'file:///repo/missing',
            'canonical_uri': null,
            'symlink_hops': [],
          },
        ]);
        edit(a, b);
        expect(
          () => validateHelper(a, b),
          valid ? returnsNormally : throwsFormatException,
        );
      });
    }

    scenario('empty-hops-all-input-kinds', (a, b) {}, valid: true);
    scenario('v1-rejected', (a, b) {
      a['protocol_version'] = 1;
      b['protocol_version'] = 1;
    });
    for (final index in [0, 3, 4]) {
      scenario(
        'missing-hops-kind-$index',
        (a, b) => b['inputs'][index].remove('symlink_hops'),
      );
    }
    scenario('nonarray-hops', (a, b) => hops(b, null));
    scenario('nonobject-hop', (a, b) => hops(b, ['link']));
    for (final field in ['observed_uri', 'target']) {
      scenario(
        'missing-$field',
        (a, b) => hops(b, [Map.of(hop)..remove(field)]),
      );
    }
    scenario(
      'extra-hop-key',
      (a, b) => hops(b, [
        {...hop, 'hash': 'a' * 64},
      ]),
    );
    // Preserve legacy scenario names and UTF-16 code units, including lone
    // surrogates. A JSON/UTF-8 roundtrip here could replace the invalid target.
    for (final (name, target) in <(String, Object?)>[
      ("invalid-target-''", ''),
      (r"invalid-target-'\x00'", '\x00'),
      (r"invalid-target-'\ud800'", '\ud800'),
      (r"invalid-target-'\udfff'", '\udfff'),
      ('invalid-target-None', null),
      ('invalid-target-1', 1),
    ]) {
      scenario(
        name,
        (a, b) => hops(b, [
          {...hop, 'target': target},
        ]),
      );
    }
    for (final uri in [
      'file:///',
      'file:///C:/',
      'file:///repo/link/',
      'file://remote/link',
      'file:///repo/link?q',
      'file:///repo/link#f',
      'file:///repo/./link',
      'file:///repo/%FF',
      'file:///repo/%6cink',
      'file:///repo/link\n',
      'relative/link',
    ]) {
      scenario(
        'invalid-uri-$uri',
        (a, b) => hops(b, [
          {...hop, 'observed_uri': uri},
        ]),
      );
    }
    for (final target in [
      '/',
      '../src/./dep',
      '/outside/root',
      'e\u0301',
      '\ufffd',
      '\u{1f680}',
    ]) {
      scenario(
        "raw-target-'$target'",
        (a, b) => hops(b, [
          {...hop, 'target': target},
        ]),
        valid: true,
      );
    }
    scenario(
      'absent-with-ancestor-hop',
      (a, b) => b['inputs'][4].addAll({
        'observed_uri': 'file:///repo/link/missing',
        'symlink_hops': [hop],
      }),
      valid: true,
    );
    scenario(
      'directory-link-to-root',
      (a, b) => b['inputs'][3].addAll({
        'observed_uri': 'file:///repo/link',
        'canonical_uri': 'file:///',
        'symlink_hops': [
          {...hop, 'target': '/'},
        ],
      }),
      valid: true,
    );
    scenario(
      'completed-hop-repeated',
      (a, b) => hops(b, [hop, hop]),
      valid: true,
    );
    scenario(
      'forty-hops',
      (a, b) => hops(b, List.filled(40, hop)),
      valid: true,
    );
    scenario('forty-one-hops', (a, b) => hops(b, List.filled(41, hop)));
    void distinctRoutes(Map a, Map b) {
      hops(b, [hop]);
      b['inputs'].add({
        ...jsonDecode(jsonEncode(b['inputs'][1])) as Map,
        'id': 'alias2',
        'observed_uri': 'file:///repo/other/dep.ts',
        'symlink_hops': [
          {'observed_uri': 'file:///repo/other', 'target': './src'},
        ],
      });
    }

    scenario(
      'distinct-stable-routes-share-content',
      distinctRoutes,
      valid: true,
    );
    scenario('shared-link-conflict-needs-aggregation', (a, b) {
      distinctRoutes(a, b);
      b['inputs'].last['symlink_hops'] = [
        {...hop, 'target': './changed-route'},
      ];
    }, valid: true);
    scenario('valid-baseline-with-freshness-change', (a, b) {
      hops(b, [hop]);
      b['status'] = 'incomplete';
      b['tool_errors'] = [
        {
          'code': 'INPUT_CHANGED',
          'message': 'Route changed',
          'path': null,
          'source_range': null,
        },
      ];
    }, valid: true);
    assert(count == 41);
  });
}
