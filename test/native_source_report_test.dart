import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

List<Map<String, dynamic>> events(
  String path, {
  String name = 'example',
  bool skipped = false,
  String? reason,
}) => [
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
    'skipped': skipped,
    'hidden': false,
  },
  {'type': 'done', 'success': true},
];
void main() {
  test('Linux installer guards bind all exact cases, hosts and reasons', () {
    const path = 'test/linux_installer_builder_test.dart';
    const reason = 'Requires Linux dpkg archive packaging.';
    final names = [
      'packages exact payload, modes, metadata and launcher',
      for (final mutation in [
        'target',
        'commit',
        'version',
        'schema',
        'helper',
        'bytes',
        'mode',
        'extra',
        'link',
        'inventory path',
        'oversize',
      ])
        'rejects $mutation before publication',
      'refuses existing output including dangling symlinks',
      'resolves output parent aliases before making missing directories',
      'rejects aliased bundle',
      for (final fault in ['command failure', 'payload', 'launcher', 'winner'])
        'cleans staging and refuses $fault',
    ];
    expect(names, hasLength(19));
    for (final target in sourceTargets) {
      for (final name in names) {
        final report = () => summarizeTests(
          events(path, name: name, skipped: true, reason: reason),
          {path},
          target,
        );
        if (target == 'linux-x64') {
          expect(report, throwsFormatException);
        } else {
          expect((report()['skipped'] as List).single['reason'], reason);
        }
        for (final invalid in [null, '', 'dpkg-deb unavailable', '$reason ']) {
          expect(
            () => summarizeTests(
              events(path, name: name, skipped: true, reason: invalid),
              {path},
              target,
            ),
            throwsFormatException,
          );
        }
        expect(expectedSkip(target, '$path.other', name, reason), isFalse);
        expect(expectedSkip(target, path, '$name extra', reason), isFalse);
      }
      // Even an inapplicable platform must register actual visible cases.
      final empty = events(path);
      empty[1]['test'].addAll({
        'name': 'loading $path',
        'groupIDs': [],
        'url': null,
      });
      empty[2]['hidden'] = true;
      expect(
        () => summarizeTests(empty, {path}, target),
        throwsFormatException,
      );
    }
  });

  test(
    'installation directory skips bind the exact platform and fixture reason',
    () {
      const path = 'test/installation_directory_test.dart';
      const cases = {
        'compares physical modes only when requested': 'POSIX mode fixture',
        'rejects a Windows junction root': 'Windows reparse fixture',
        'rejects a Windows junction parent': 'Windows reparse fixture',
        'rejects a Windows file symlink': 'Windows reparse fixture',
      };
      for (final entry in cases.entries) {
        for (final target in sourceTargets) {
          final allowed = entry.value == 'POSIX mode fixture'
              ? target == 'windows-x64'
              : target != 'windows-x64';
          expect(expectedSkip(target, path, entry.key, entry.value), allowed);
          expect(
            expectedSkip(target, path, entry.key, 'fixture unavailable'),
            isFalse,
          );
          expect(
            expectedSkip(target, path, '${entry.key} changed', entry.value),
            isFalse,
          );
          expect(
            expectedSkip(
              target,
              'test/other_test.dart',
              entry.key,
              entry.value,
            ),
            isFalse,
          );
        }
      }
    },
  );
  test('complete visible reporter lifecycle binds exact suite inventory', () {
    const path = 'test/example_test.dart';
    expect(summarizeTests(events(path), {path}, 'linux-x64'), {
      'suites': [path],
      'passed': 1,
      'skipped': [],
    });
    expect(
      () =>
          summarizeTests(events(path), {'test/missing_test.dart'}, 'linux-x64'),
      throwsFormatException,
    );
  });
  test(
    'missing, duplicate, failed and unmatched lifecycle records are rejected',
    () {
      const path = 'test/example_test.dart';
      for (final mutate in <void Function(List<Map<String, dynamic>>)>[
        (e) => e.removeLast(),
        (e) => e.removeAt(2),
        (e) => e.removeAt(1),
        (e) => e.insert(1, e[0]),
        (e) => e.insert(2, e[1]),
        (e) => e.insert(3, e[2]),
        (e) => e.add(e.last),
        (e) => e[2]['result'] = 'failure',
        (e) => e[2]['result'] = 'error',
        (e) => e[3]['success'] = false,
        (e) => e.insert(2, {'type': 'error', 'testID': 1}),
        (e) => e[1]['test']['suiteID'] = 90,
      ]) {
        final records = events(path);
        mutate(records);
        expect(
          () => summarizeTests(records, {path}, 'linux-x64'),
          throwsFormatException,
        );
      }
      expect(
        () => summarizeTests(events(path), {path}, 'unsupported'),
        throwsFormatException,
      );
      expect(
        () => summarizeTests(
          [
            {'type': 'done', 'success': true},
          ],
          {},
          'linux-x64',
        ),
        throwsFormatException,
      );
    },
  );
  test('exact raw-path loaders and hooks coexist with visible tests on all targets', () {
    const path = 'test/example_test.dart';
    for (final target in sourceTargets) {
      final raw = target == 'windows-x64' ? path.replaceAll('/', '\\') : path;
      final records = events(raw)..removeLast();
      for (final name in ['loading $raw', '(setUpAll)', '(tearDownAll)']) {
        final id = records.length;
        records.addAll([
          {
            'type': 'testStart',
            'test': {
              'id': id,
              'suiteID': 0,
              'name': name,
              'groupIDs': [],
              'url': null,
            },
          },
          {
            'type': 'testDone',
            'testID': id,
            'result': 'success',
            'hidden': true,
            'skipped': false,
          },
        ]);
      }
      records.add({'type': 'done', 'success': true});
      expect(summarizeTests(records, {path}, target)['passed'], 1);
      for (final mutation in <Map<String, dynamic>>[
        {'name': 'loading test/other_test.dart'},
        {'name': 'loading $raw '},
        {'name': 'loading test/../$raw'},
        {
          'groupIDs': [0],
        },
        {'url': 'file:///test.dart'},
        {'name': 'user test'},
      ]) {
        final changed = jsonDecode(jsonEncode(records)) as List;
        (changed[3]['test'] as Map).addAll(mutation);
        expect(
          () => summarizeTests(changed.cast<Map<String, dynamic>>(), {
            path,
          }, target),
          throwsFormatException,
        );
      }
      records[4]['skipped'] = true;
      expect(
        () => summarizeTests(records, {path}, target),
        throwsFormatException,
      );
    }
  });
  test('noncanonical inventory and load-only suites cannot replace visible execution', () {
    const path = 'test/example_test.dart';
    for (final bad in [
      './$path',
      '/$path',
      'test/../$path',
      'test//example_test.dart',
      'C:\\$path',
      '$path\u0000',
    ]) {
      expect(
        () => summarizeTests(events(bad), {path}, 'windows-x64'),
        throwsFormatException,
      );
    }
    for (final target in sourceTargets) {
      for (final emptyPath in [path, 'test/linux_unprivileged_cli_test.dart']) {
        final records = events(emptyPath);
        records[1]['test'].addAll({
          'name': 'loading $emptyPath',
          'groupIDs': [],
          'url': null,
        });
        records[2]['hidden'] = true;
        expect(
          () => summarizeTests(records, {emptyPath}, target),
          throwsFormatException,
        );
      }
    }
    for (final skipped in [true, false]) {
      final hidden = events(path, skipped: skipped);
      hidden[2]['hidden'] = true;
      expect(
        () => summarizeTests(hidden, {path}, 'linux-x64'),
        throwsFormatException,
      );
    }
  });
  test(
    'new platform guards require exact file name reason and inapplicable host',
    () {
      const cases = [
        (
          'test/preparation_process_test.dart',
          'stderr open failure closes the already opened stdout handle',
          'Linux descriptor ownership observation',
          {'macos-arm64', 'windows-x64'},
        ),
        (
          'test/prepare_native_acceptance_test.dart',
          'Git discovery skips a nonexecutable earlier PATH entry',
          'POSIX executable permission regression',
          {'windows-x64'},
        ),
        (
          'test/windows_assembly_assertions_test.dart',
          'Windows assembly guards reject execution on a non-Windows host',
          'Requires a non-Windows host.',
          {'windows-x64'},
        ),
        (
          'test/check_inventory_fixture_test.dart',
          'native junction launch preserves spaces, Unicode and apostrophes',
          'Requires native Windows junction creation.',
          {'linux-x64', 'macos-arm64'},
        ),
        (
          'test/flutter_sdk_copy_test.dart',
          'Windows deep source and destination remain real isolated hardlinks',
          'Requires native Windows hardlinks.',
          {'linux-x64', 'macos-arm64'},
        ),
        (
          'test/native_fixture_capability_test.dart',
          'WindowsOutputLockTest.test_real_sharing_conflict_prevents_truncation_and_releases',
          'Win32 sharing-mode fixture is Windows-specific',
          {'linux-x64', 'macos-arm64'},
        ),
        (
          'test/native_acceptance_windows_capture_test.dart',
          'Windows pipe sinks preserve default buffering and allow no-buffer capture',
          'Native Windows pipe control.',
          {'linux-x64', 'macos-arm64'},
        ),
        (
          'test/installation_identity_test.dart',
          'source identity times out and reaps its direct Git child',
          'POSIX direct-child timeout fixture',
          {'windows-x64'},
        ),
        (
          'test/installation_identity_test.dart',
          'source identity preserves selected PATH and replacement environment',
          'POSIX controlled Git fixture',
          {'windows-x64'},
        ),
        (
          'test/installation_identity_test.dart',
          'runtime identity uses assembler cwd for relative PATH',
          'Unix assembler PATH/cwd semantics',
          {'windows-x64'},
        ),
        (
          'test/installation_identity_test.dart',
          'runtime identity combines streams and rejects nonzero exits',
          'POSIX runtime script fixture',
          {'windows-x64'},
        ),
        (
          'test/installation_identity_test.dart',
          'runtime identity normalizes newlines in each stream before joining',
          'POSIX runtime script fixture',
          {'windows-x64'},
        ),
        (
          'test/installation_identity_test.dart',
          'runtime identity times out and reaps its direct child',
          'POSIX direct-child timeout fixture',
          {'windows-x64'},
        ),
        (
          'test/catalogue_export_test.dart',
          'overwrite rejects a FIFO with a live reader before sending content',
          'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.',
          {'windows-x64'},
        ),
        (
          'test/catalogue_export_test.dart',
          'live FIFO reader observes bytes written after readiness',
          'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.',
          {'windows-x64'},
        ),
      ];
      for (final (path, name, reason, allowedTargets) in cases) {
        for (final target in sourceTargets) {
          final accepts = allowedTargets.contains(target);
          final call = () => summarizeTests(
            events(path, name: name, skipped: true, reason: reason),
            {path},
            target,
          );
          if (accepts) {
            expect((call()['skipped'] as List).single['reason'], reason);
          } else {
            expect(call, throwsFormatException);
          }
          for (final invalid in [null, '', 'fixture missing', '$reason ']) {
            expect(
              () => summarizeTests(
                events(path, name: name, skipped: true, reason: invalid),
                {path},
                target,
              ),
              throwsFormatException,
            );
          }
          expect(expectedSkip(target, '$path.other', name, reason), isFalse);
          expect(expectedSkip(target, path, '$name extra', reason), isFalse);
        }
      }
    },
  );
  test('Linux unprivileged guards bind exact identity and host', () {
    const path = 'test/linux_unprivileged_cli_test.dart';
    const reason = 'Requires Linux unprivileged exec and identity semantics.';
    for (final name in [
      'unprivileged CLI child replaces its PID and preserves transport',
      'unprivileged CLI child uses uid 65534 only for a root caller',
      'failed exec remains a visible child failure',
    ]) {
      for (final target in sourceTargets) {
        final call = () => summarizeTests(
          events(path, name: name, skipped: true, reason: reason),
          {path},
          target,
        );
        if (target == 'linux-x64') {
          expect(call, throwsFormatException);
        } else {
          expect((call()['skipped'] as List).single['reason'], reason);
        }
        for (final invalid in [null, '', 'fixture missing', '$reason ']) {
          expect(
            () => summarizeTests(
              events(path, name: name, skipped: true, reason: invalid),
              {path},
              target,
            ),
            throwsFormatException,
          );
        }
        expect(expectedSkip(target, '$path.other', name, reason), isFalse);
        expect(expectedSkip(target, path, '$name extra', reason), isFalse);
      }
    }
  });
  test('capability skips retain their exact reason without admitting missing dependencies', () {
    const path = 'test/physical_paths_test.dart';
    final records = events(
      path,
      name:
          'case-insensitive source lookup does not relax exact scope spelling',
      skipped: true,
    );
    records.insert(2, {
      'type': 'print',
      'messageType': 'skip',
      'testID': 1,
      'message': 'Requires a case-insensitive filesystem.',
    });
    expect(
      (summarizeTests(records, {path}, 'linux-x64')['skipped'] as List)
          .single['reason'],
      'Requires a case-insensitive filesystem.',
    );
    records[2]['message'] = 'fixture missing';
    expect(
      () => summarizeTests(records, {path}, 'linux-x64'),
      throwsFormatException,
    );
    const adversarial = 'test/dart_adversarial_test.dart';
    expect(
      () => summarizeTests(
        events(
          adversarial,
          name: 'a stable socket entry outside scope does not change inventory identity',
          skipped: true,
          reason: 'Host refuses Unix-domain server socket binding (errno 9).',
        ),
        {adversarial},
        'linux-x64',
      ),
      throwsFormatException,
    );
    expect(
      () => summarizeTests(
        events(
          'test/dart_flutter_test.dart',
          skipped: true,
          reason: 'Requires prepared Flutter fixture.',
        ),
        {'test/dart_flutter_test.dart'},
        'linux-x64',
      ),
      throwsFormatException,
    );
  });
}
