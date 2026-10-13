// Exact source-test inventory and pinned Dart JSON reporter lifecycle.
const sourceTargets = {'linux-x64', 'macos-arm64', 'windows-x64'};

bool expectedSkip(String target, String path, String name, String? reason) {
  final entry = (path, name);
  const windows = {
    (
      'test/windows_native_probe_test.dart',
      'Windows x64 CLI init creates both files in a fresh root',
    ),
    (
      'test/physical_paths_test.dart',
      'Windows root canonicalization follows an absolute directory symbolic link',
    ),
    (
      'test/physical_paths_test.dart',
      'Windows root canonicalization follows a local directory junction',
    ),
  };
  final linux = {
    (
      'test/dart_adversarial_test.dart',
      'unreadable selected analysis options cannot become an absent clean configuration',
    ),
    for (final kind in ['ordinary', 'fifo', 'socket'])
      (
        'test/dart_adversarial_test.dart',
        'a stable $kind entry outside scope does not change inventory identity',
      ),
    (
      'test/input_mutations_test.dart',
      'an unreadable selected directory is a corpus gap, not an empty clean region',
    ),
    for (final language in ['dart', 'typescript'])
      (
        'test/physical_compilers_test.dart',
        '$language hardlinks retain pathname owners and exact boundary decisions',
      ),
    (
      'test/physical_paths_test.dart',
      'an exact NFC scope cannot hide a differently normalized physical entry',
    ),
  };
  const posix = {
    (
      'test/physical_paths_test.dart',
      'unrepresentable and NFC-colliding entries are incomplete without a global failure',
    ),
    (
      'test/physical_paths_test.dart',
      'a literal POSIX backslash filename cannot become a clean absent portable path',
    ),
  };
  if (target == 'windows-x64' &&
      path == 'test/catalogue_export_test.dart' &&
      const {
        'overwrite rejects a FIFO with a live reader before sending content',
        'live FIFO reader observes bytes written after readiness',
      }.contains(name) &&
      reason ==
          'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.') {
    return true;
  }
  if (entry ==
          (
            'test/physical_paths_test.dart',
            'case-insensitive source lookup does not relax exact scope spelling',
          ) &&
      reason == 'Requires a case-insensitive filesystem.')
    return true;
  // These exact cases are new platform-qualified fixture controls. Each reason
  // matches its owning test's Platform guard; dependencies never qualify.
  const windowsOnly = {
    (
      'test/check_inventory_fixture_test.dart',
      'native junction launch preserves spaces, Unicode and apostrophes',
    ): 'Requires native Windows junction creation.',
    (
      'test/flutter_sdk_copy_test.dart',
      'Windows deep source and destination remain real isolated hardlinks',
    ): 'Requires native Windows hardlinks.',
    (
      'test/native_fixture_capability_test.dart',
      'WindowsOutputLockTest.test_real_sharing_conflict_prevents_truncation_and_releases',
    ): 'Win32 sharing-mode fixture is Windows-specific',
    (
      'test/native_acceptance_windows_capture_test.dart',
      'Windows pipe sinks preserve default buffering and allow no-buffer capture',
    ): 'Native Windows pipe control.',
  };
  const linuxOnly = {
    (
      'test/linux_unprivileged_cli_test.dart',
      'unprivileged CLI child replaces its PID and preserves transport',
    ): 'Requires Linux unprivileged exec and identity semantics.',
    (
      'test/linux_unprivileged_cli_test.dart',
      'unprivileged CLI child uses uid 65534 only for a root caller',
    ): 'Requires Linux unprivileged exec and identity semantics.',
    (
      'test/linux_unprivileged_cli_test.dart',
      'failed exec remains a visible child failure',
    ): 'Requires Linux unprivileged exec and identity semantics.',
    (
      'test/preparation_process_test.dart',
      'stderr open failure closes the already opened stdout handle',
    ): 'Linux descriptor ownership observation',
  };
  const posixOnly = {
    (
      'test/prepare_native_acceptance_test.dart',
      'Git discovery skips a nonexecutable earlier PATH entry',
    ): 'POSIX executable permission regression',
    (
      'test/windows_assembly_assertions_test.dart',
      'Windows assembly guards reject execution on a non-Windows host',
    ): 'Requires a non-Windows host.',
    (
      'test/installation_identity_test.dart',
      'source identity times out and reaps its direct Git child',
    ): 'POSIX direct-child timeout fixture',
    (
      'test/installation_identity_test.dart',
      'source identity preserves selected PATH and replacement environment',
    ): 'POSIX controlled Git fixture',
    (
      'test/installation_identity_test.dart',
      'runtime identity uses assembler cwd for relative PATH',
    ): 'Unix assembler PATH/cwd semantics',
    (
      'test/installation_identity_test.dart',
      'runtime identity combines streams and rejects nonzero exits',
    ): 'POSIX runtime script fixture',
    (
      'test/installation_identity_test.dart',
      'runtime identity normalizes newlines in each stream before joining',
    ): 'POSIX runtime script fixture',
    (
      'test/installation_identity_test.dart',
      'runtime identity times out and reaps its direct child',
    ): 'POSIX direct-child timeout fixture',
  };
  if (target != 'windows-x64' &&
      windowsOnly.containsKey(entry) &&
      windowsOnly[entry] == reason)
    return true;
  if (target != 'linux-x64' &&
      linuxOnly.containsKey(entry) &&
      linuxOnly[entry] == reason)
    return true;
  if (target == 'windows-x64' &&
      posixOnly.containsKey(entry) &&
      posixOnly[entry] == reason)
    return true;
  return (target != 'windows-x64' && windows.contains(entry)) ||
      (target != 'linux-x64' && linux.contains(entry)) ||
      (target == 'windows-x64' && posix.contains(entry));
}

Map<String, Object?> summarizeTests(
  Iterable<Map<String, dynamic>> events,
  Set<String> expectedFiles,
  String target,
) {
  if (!sourceTargets.contains(target))
    throw FormatException('Unsupported source target: $target');
  final suites = <int, String>{}, rawPaths = <int, String>{};
  final tests = <int, Map<String, dynamic>>{};
  final finished = <int>{}, accounted = <int>{};
  final reasons = <int, String>{};
  final skipped = <Map<String, Object?>>[];
  var passed = 0, completed = false;
  for (final event in events) {
    if (completed)
      throw const FormatException('Source event after terminal result');
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'] as Map<String, dynamic>;
        final id = suite['id'] as int, raw = suite['path'] as String;
        final path = raw.replaceAll('\\', '/');
        if (suites.containsKey(id) ||
            suites.containsValue(path) ||
            !expectedFiles.contains(path)) {
          throw const FormatException('Duplicate or unexpected source suite');
        }
        suites[id] = path;
        rawPaths[id] = raw;
      case 'testStart':
        final test = event['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        if (tests.containsKey(id) || !suites.containsKey(test['suiteID'])) {
          throw const FormatException('Duplicate source test or unknown suite');
        }
        tests[id] = test;
      case 'print':
        if (event['messageType'] == 'skip')
          reasons[event['testID'] as int] = event['message'] as String;
      case 'testDone':
        final id = event['testID'] as int;
        if (event['result'] != 'success' ||
            !tests.containsKey(id) ||
            !finished.add(id) ||
            event['hidden'] is! bool ||
            event['skipped'] is! bool) {
          throw const FormatException(
            'Failed, unmatched or duplicate source test result',
          );
        }
        final test = tests[id]!, suite = test['suiteID'] as int;
        final path = suites[suite]!, name = test['name'] as String;
        if (event['hidden'] == true) {
          final groups = test['groupIDs'];
          final loading =
              name == 'loading ${rawPaths[suite]}' &&
              groups is List &&
              groups.isEmpty &&
              test['url'] == null;
          final hook = name == '(setUpAll)' || name == '(tearDownAll)';
          if (event['skipped'] == true || !(loading || hook)) {
            throw const FormatException('Unexpected hidden source test result');
          }
          continue;
        }
        accounted.add(suite);
        if (event['skipped'] == true) {
          final metadata = test['metadata'] as Map<String, dynamic>;
          final declared = metadata['skipReason'] as String?;
          final reason = declared == null || declared.isEmpty
              ? reasons[id]
              : declared;
          if (!expectedSkip(target, path, name, reason))
            throw FormatException('Unapproved source test skip: $path: $name');
          skipped.add({
            'file': path,
            'name': name,
            'reason': reason,
            'applicability':
                'Existing explicit source-fixture OS/filesystem guard',
          });
        } else {
          passed++;
        }
      case 'done':
        if (event['success'] != true)
          throw const FormatException('Source test suite did not succeed');
        completed = true;
      case 'start':
      case 'allSuites':
      case 'group':
      case 'debug':
        break;
      default:
        throw FormatException(
          'Unexpected source reporter event: ${event['type']}',
        );
    }
  }
  if (!completed ||
      suites.length != expectedFiles.length ||
      tests.isEmpty ||
      finished.length != tests.length ||
      accounted.length != suites.length) {
    throw const FormatException(
      'Incomplete source test suite inventory or terminal results',
    );
  }
  return {
    'suites': expectedFiles.toList()..sort(),
    'passed': passed,
    'skipped': skipped,
  };
}
