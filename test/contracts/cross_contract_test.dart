import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../contracts/assignment/assignment_reference.dart';
import '../../contracts/compatibility/lexical_reference.dart' show normalize;
import '../../contracts/helper/validate_contract.dart';
import '../../contracts/json/validate_contract.dart';
import '../../tool/validation/json_schema.dart';

Map _read(String path) =>
    jsonDecode(File('contracts/$path').readAsStringSync());
Map _fixture(String name) => _read('json/fixtures/$name');
Map _copy(Map value) => jsonDecode(jsonEncode(value));

void main() {
  final schema = ContractSchema(_read('json/public-result.schema.json'));
  void contractCase(
    String name,
    String fixture,
    void Function(Map) edit, {
    bool valid = false,
  }) {
    test(name, () {
      final value = _fixture(fixture);
      edit(value);
      var accepted = schema.errors(value).isEmpty;
      if (accepted) {
        try {
          invariants(value);
        } on FormatException {
          accepted = false;
        }
      }
      expect(accepted, valid);
    });
  }

  const complete = 'check-complete-fact.json',
      incomplete = 'check-mixed-incomplete.json';
  contractCase(
    'fact-context-not-candidate',
    complete,
    (x) => x['payload']['facts']['edges'][0]['context_id'] = 'typescript:other',
  );
  contractCase(
    'absent-probe-with-present-hash',
    complete,
    (x) => x['payload']['input_identity']['inputs'].add({
      'kind': 'resolution',
      'location': {'kind': 'repository', 'path': 'src/absent.ts'},
      'presence': 'absent',
      'hash': 'sha256:${'a' * 64}',
    }),
  );
  contractCase(
    'assigned-incomplete-discovery',
    complete,
    (x) => x['payload']['coverage']['files'][0]['discovery_complete'] = false,
  );
  for (final outcome in [
    'planned',
    'created',
    'conflict',
    'rolled_back',
    'partial',
  ]) {
    contractCase('init-$outcome-with-policy-identity', 'init-$outcome.json', (
      x,
    ) {
      x['policy_path'] = 'architecture.yaml';
      x['policy_hash'] = 'sha256:${'a' * 64}';
    });
  }
  contractCase('incomplete-evidence-negative-status', incomplete, (x) {
    x['status'] = 'negative';
    x['exit_code'] = 1;
  });
  for (final (raw, expected) in [
    ('src/A.ts', 'src/A.ts'),
    ('src/a.ts', 'src/a.ts'),
  ]) {
    test('lexical-positive-$raw', () => expect(normalize(raw), expected));
  }
  for (final supported in [false, true]) {
    for (final discovered in [false, true]) {
      for (final count in [0, 1, 2]) {
        test(
          'assignment supported=$supported discovered=$discovered candidates=$count',
          () {
            final file = {
              'supported_source': supported,
              'discovery_complete': discovered,
              'candidates': [
                for (var i = 0; i < count; i++)
                  {'project_id': '$i', 'context_id': 'typescript:$i'},
              ],
            };
            final expected = !supported
                ? 'unsupported'
                : !discovered
                ? 'failed'
                : ['missing', 'assigned', 'ambiguous'][count];
            expect(assign(file), expected);
          },
        );
      }
    }
  }
  contractCase(
    'policy-hash-disagrees-input-identity',
    complete,
    (x) => x['payload']['input_identity']['inputs'][0]['hash'] =
        'sha256:${'f' * 64}',
  );
  contractCase(
    'assigned-with-unresolved-project',
    complete,
    (x) => x['payload']['coverage']['files'][0]['unresolved_project_ids'] = [
      'other',
    ],
  );
  contractCase(
    'complete-with-unfinished-recheck',
    complete,
    (x) => x['payload']['input_identity']['rechecked'] = false,
  );
  contractCase(
    'complete-with-changed-source',
    complete,
    (x) => x['payload']['input_identity']['changed_inputs'] = [
      {'kind': 'repository', 'path': 'src/app/main.ts'},
    ],
  );
  const rootLocation = {'kind': 'external', 'canonical_file_uri': 'file:///'};
  final rootInventory = {
    'kind': 'inventory',
    'location': rootLocation,
    'presence': 'present',
    'hash': 'sha256:${'e' * 64}',
  };
  contractCase(
    'public-external-filesystem-root-inventory',
    complete,
    (x) => x['payload']['input_identity']['inputs'].add(_copy(rootInventory)),
    valid: true,
  );
  contractCase(
    'public-changed-external-filesystem-root-inventory',
    incomplete,
    (x) {
      final identity = x['payload']['input_identity'];
      identity['inputs'].add(_copy(rootInventory));
      identity['changed_inputs'].add(_copy(rootLocation));
      x['payload']['unknowns'][0]['code'] = 'INPUT_CHANGED';
      x['payload']['unknowns'][0]['message'] = 'Root inventory changed';
    },
    valid: true,
  );
  contractCase(
    'public-changed-root-without-inventory-evidence',
    incomplete,
    (x) => x['payload']['input_identity']['changed_inputs'] = [
      _copy(rootLocation),
    ],
  );
  test('matching helper root observation is outside file:///repo', () {
    final request = _read('helper/fixtures/valid-request.json');
    final response = _read('helper/fixtures/valid-response.json');
    response['inputs'].add({
      'id': 'root-inventory',
      'kind': 'directory',
      'observed_uri': 'file:///',
      'canonical_uri': 'file:///',
      'sha256': 'e' * 64,
      'symlink_hops': [],
    });
    expect(() => validateHelper(request, response), returnsNormally);
  });
  for (final kind in [
    'policy',
    'source',
    'config',
    'manifest',
    'resolution',
    'sdk',
  ]) {
    contractCase(
      'public-filesystem-root-not-$kind',
      complete,
      (x) => x['payload']['input_identity']['inputs'].add({
        ...rootInventory,
        'kind': kind,
      }),
    );
  }
  for (final kind in ['inventory', 'resolution']) {
    contractCase('public-filesystem-root-not-absent-$kind', incomplete, (x) {
      final identity = x['payload']['input_identity'];
      identity['inputs'].add({
        ...rootInventory,
        'kind': kind,
        'presence': 'absent',
        'hash': null,
      });
    });
  }
  for (final field in ['canonical_file_uri', 'via_path']) {
    contractCase(
      'public-edge-root-not-$field',
      complete,
      (x) =>
          x['payload']['facts']['edges'][0]['resolution'][field] = 'file:///',
    );
  }
  for (final field in ['observed_file_uri', 'canonical_file_uri']) {
    contractCase('public-file-alias-root-not-$field', complete, (x) {
      final alias = {
        'observed_file_uri': 'file:///repo/a.ts',
        'canonical_file_uri': 'file:///repo/b.ts',
      };
      alias[field] = 'file:///';
      x['payload']['input_identity']['aliases'] = [alias];
    });
  }
  contractCase(
    'public-changed-root-requires-matching-inventory-location',
    incomplete,
    (x) {
      x['payload']['input_identity']['inputs'].add({
        ...rootInventory,
        'location': {'kind': 'external', 'canonical_file_uri': 'file:///other'},
      });
      x['payload']['input_identity']['changed_inputs'] = [_copy(rootLocation)];
    },
  );
}
