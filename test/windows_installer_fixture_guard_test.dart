import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

void main() {
  test(
    'installer fixture skips require exact case reason and opposite host',
    () {
      const cases = [
        (
          'test/windows_installer_registry_test.dart',
          'native registry rejects unsupported ABI before opening keys',
          'Non-native Windows registry host control',
          true,
        ),
        (
          'test/windows_installer_fixture_test.dart',
          'deletion-only lock and entry removal reject unsupported hosts',
          'Non-native Windows installer fixture host control',
          true,
        ),
        (
          'test/windows_installer_fixture_test.dart',
          'Windows deletion lock permits reads and writes but denies deletion',
          'Native Windows deletion-only sharing fixture',
          false,
        ),
        (
          'test/windows_installer_fixture_test.dart',
          'Windows directory entry removal never traverses a junction target',
          'Native Windows nonrecursive junction removal fixture',
          false,
        ),
      ];
      for (final (path, name, reason, nativeSkip) in cases) {
        for (final target in sourceTargets) {
          final allowed = (target == 'windows-x64') == nativeSkip;
          final report = () =>
              summarizeTests(events(path, name, reason), {path}, target);
          if (allowed) {
            expect((report()['skipped'] as List).single['reason'], reason);
          } else {
            expect(report, throwsFormatException);
          }
          for (final wrong in [
            null,
            '',
            'native API unavailable',
            '$reason ',
          ]) {
            expect(
              () => summarizeTests(events(path, name, wrong), {path}, target),
              throwsFormatException,
            );
          }
          expect(expectedSkip(target, '$path.other', name, reason), isFalse);
          expect(expectedSkip(target, path, '$name changed', reason), isFalse);
          final empty = events(path, 'loading $path', null);
          (empty[1]['test'] as Map<String, dynamic>).addAll({
            'groupIDs': [],
            'url': null,
          });
          empty[2].addAll({'hidden': true, 'skipped': false});
          expect(
            () => summarizeTests(empty, {path}, target),
            throwsFormatException,
          );
        }
      }
    },
  );
}

List<Map<String, dynamic>> events(String path, String name, String? reason) => [
  {
    'type': 'suite',
    'suite': {'id': 0, 'path': path},
  },
  {
    'type': 'testStart',
    'test': <String, dynamic>{
      'id': 1,
      'suiteID': 0,
      'name': name,
      'metadata': {'skipReason': reason},
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
