import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

void main() {
  const path = 'test/native_macos_installer_probe_test.dart';
  const reason = 'POSIX macOS installer lifecycle fixture';
  const names = [
    'synthetic lifecycle builds old then final, upgrades and removes owned files',
    'filesystem refusals include dangling links and precede output or commands',
    'receipt query failures never permit compiler or installation commands',
    'verified fallback cleans failed inspect and preserves primary failure',
    'mixed root preserves unrelated bytes and only removes exact marker',
    'temporary cleanup cannot replace an active primary failure',
  ];
  List<Map<String, dynamic>> events(String name, String? skipReason) => [
    {
      'type': 'suite',
      'suite': {'id': 0, 'path': path},
    },
    {
      'type': 'testStart',
      'test': {
        'id': 1,
        'suiteID': 0,
        'name': name,
        'metadata': {'skipReason': skipReason},
      },
    },
    {
      'type': 'testDone',
      'testID': 1,
      'result': 'success',
      'skipped': true,
      'hidden': false,
    },
    {'type': 'done', 'success': true},
  ];
  test('macOS lifecycle Windows skips bind all six exact visible cases', () {
    expect(names.length, 6);
    for (final name in names) {
      for (final target in sourceTargets) {
        final report = () =>
            summarizeTests(events(name, reason), {path}, target);
        if (target == 'windows-x64') {
          expect((report()['skipped'] as List).single['reason'], reason);
        } else {
          expect(report, throwsFormatException);
        }
        if (target != 'windows-x64') continue;
        for (final wrong in [null, '', 'missing pkgbuild', '$reason ']) {
          expect(
            () => summarizeTests(events(name, wrong), {path}, target),
            throwsFormatException,
          );
        }
        expect(expectedSkip(target, '$path.other', name, reason), isFalse);
        expect(expectedSkip(target, path, '$name changed', reason), isFalse);
      }
    }
  });
  test('non-macOS host control admits only its exact native Mac skip', () {
    const name =
        'native lifecycle refuses wrong host before output or commands';
    const hostReason = 'Non-native macOS host control';
    for (final target in sourceTargets) {
      expect(
        expectedSkip(target, path, name, hostReason),
        target == 'macos-arm64',
      );
      if (target != 'macos-arm64') continue;
      for (final wrong in [null, '', 'missing pkgbuild', '$hostReason ']) {
        expect(expectedSkip(target, path, name, wrong), isFalse);
      }
      expect(expectedSkip(target, '$path.other', name, hostReason), isFalse);
      expect(expectedSkip(target, path, '$name changed', hostReason), isFalse);
    }
  });
}
