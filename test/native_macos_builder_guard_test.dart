import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

void main() {
  const path = 'test/macos_installer_builder_test.dart';
  const reason = 'POSIX macOS installer staging fixture';
  const names = [
    'stages exact payload and unchanged lifecycle without source commit policy',
    'rejects each caller policy violation without creating output',
    'rejects restricted and reserved paths, including uninstall subtree',
    'rejects bytes, modes, extra files and symlink payloads',
    'rejects fresh output inside input directly or through aliased parent',
    'preserves existing output and dangling links',
    'removes private copied payload after lifecycle input failure',
    'owned inventory includes every copied file and uninstall with actual modes',
    'explicit command fixture captures unsigned pkgbuild arguments and evidence',
    'native build refuses actual non-macOS host before any mutation',
    'restricted child umask keeps package directories traversable and stage private',
    'shared producer manifest mode precondition rejects 0755 before staging',
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
  test('macOS builder Windows skips bind all twelve exact visible cases', () {
    expect(names.length, 12);
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
        'native build refuses actual non-macOS host before any mutation';
    const hostReason = 'Non-macOS host control';
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
