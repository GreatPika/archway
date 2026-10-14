import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/release_npm_termination_receipts.dart';
import 'npm_termination_receipt_fixtures.dart';

void main() {
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    for (final route in ['local', 'global', 'cache']) {
      test('$target $route preserves owned termination and external observations', () {
        final proof = terminationFixture(target, route);
        final node = [
          'v24.21.0',
          {
            'linux-x64': 'linux',
            'macos-arm64': 'darwin',
            'windows-x64': 'win32',
          }[target],
          target == 'macos-arm64' ? 'arm64' : 'x64',
        ];
        void validate(Map<String, dynamic> value, [Object? npm = '11.19.0']) =>
            validateNpmTermination(value, target, route, node, npm);
        validate(proof);
        final changes = <void Function(Map)>[
          (p) => (p['termination_control']['cases'] as List).removeLast(),
          (p) =>
              p['termination_control']['cases'][0]['core_terminated'] = false,
          (p) => p['termination_control']['cases'][0]['streams_equal'] = 1,
          (p) => p['termination_control']['cases'][0]['route_exit'] = 0,
          (p) => (p['termination_control']['cases'][0] as Map).remove(
            'native_helper_terminated',
          ),
          if (target != 'windows-x64') ...[
            (p) =>
                p['termination_control']['cases'][0]['native_helper_terminated'] =
                    false,
            (p) =>
                p['termination_control']['cases'][0]['route_helper_terminated'] =
                    false,
          ],
        ];
        for (final change in changes) {
          final copy = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
          change(copy);
          expect(() => validate(copy), throwsFormatException);
        }
        for (final version in [
          '0.0.0',
          '11.18.0',
          '999.999.999',
          'v11.19.0',
          null,
        ]) {
          expect(() => validate(proof, version), throwsFormatException);
        }
      });
    }
  }
  test('cache group and external failure observations cannot be forged', () {
    final original = terminationFixture('linux-x64', 'cache');
    expect(
      () => validateNpmTermination(original, 'linux-x64', 'cache', [
        'v24.19.0',
        'linux',
        'x64',
      ], '11.19.0'),
      throwsFormatException,
    );
    void validate(Map<String, dynamic> value) => validateNpmTermination(
      value,
      'linux-x64',
      'cache',
      ['v24.21.0', 'linux', 'x64'],
      '11.19.0',
    );
    for (final mutate in <void Function(Map)>[
      (c) => c.remove('cache_group_sigint'),
      (c) => c['invocation'] = 'installed-route',
      (c) => c['cache_group_sigint']['core_terminated'] = false,
      (c) => c['cache_group_sigint']['helper_terminated'] = false,
      (c) => c['cache_group_sigint']['outer_exit'] = 0,
      (c) => c['cache_group_sigint']['core_envelope_exit'] = true,
      (c) => c['cache_group_sigint']['invocation'] =
          'selected-cached-shim-supplement',
      (c) => (c['outer_npm_pid_observations']['cases'] as List).clear(),
      (c) => c['outer_npm_pid_observations']['cases'][0]['status'] = 'PASSED',
      (c) =>
          c['outer_npm_pid_observations']['cases'][0]['observation']['stdout_bytes'] =
              -1,
      (c) =>
          c['outer_npm_pid_observations']['cases'][0]['observation']['outer_exit'] =
              2.0,
    ]) {
      final changed = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      mutate(changed['termination_control'] as Map);
      expect(() => validate(changed), throwsFormatException);
    }
  });
  test(
    'completed external observation status follows observed exit and streams',
    () {
      final proof = terminationFixture('linux-x64', 'cache');
      final boundary =
          proof['termination_control']['outer_npm_pid_observations']['cases'][0]
              as Map;
      boundary['observation'] = {
        'outer_exit': 2,
        'stdout_bytes': 0,
        'stderr_bytes': 0,
        'core_terminated': true,
        'streams_equal': true,
      };
      boundary['status'] = 'PASSED';
      void validate() => validateNpmTermination(proof, 'linux-x64', 'cache', [
        'v24.21.0',
        'linux',
        'x64',
      ], '11.19.0');
      validate();
      boundary['observation']['streams_equal'] = false;
      expect(validate, throwsFormatException);
      boundary['status'] = 'FAILED';
      validate();
    },
  );
}
