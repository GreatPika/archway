import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

Future<Directory> physicalFixture(
  String scope,
  String exclude, {
  Directory? base,
}) async {
  final root = await (base ?? Directory.systemTemp).createTemp(
    'archway-physical-',
  );
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/architecture.yaml').writeAsString('''version: 1
projects: []
scope: $scope
exclude: $exclude
nodes: []
''');
  return root;
}

Future<Map> checkPhysical(Directory root, int expectedExit) async {
  final stdout = StringBuffer(), stderr = StringBuffer();
  final exit = await CLI().run([
    '--root',
    root.path,
    'check',
  ], CliStreams(stdout, stderr));
  expect(exit, expectedExit, reason: stdout.toString());
  expect(stderr.toString(), '');
  expect(stdout.toString().split('\n'), hasLength(2));
  final report = jsonDecode(stdout.toString()) as Map;
  expect(report['exit_code'], expectedExit);
  expect(report['command'], 'check');
  expect(report['schema_version'], 1);
  return report;
}

void main() {
  test(
    'root canonicalization preserves a literal leading BOM in a link target',
    () async {
      final runnerTemp = Platform.environment['RUNNER_TEMP'];
      final temporary = await physicalFixture(
        '[]',
        '[]',
        base: Platform.isWindows && runnerTemp != null
            ? Directory(runnerTemp)
            : null,
      );
      final base = Directory(await temporary.resolveSymbolicLinks());
      print('BOM_ALIAS_TEST_ROOT=${base.path}');
      final selected = await Directory('${base.path}/\uFEFFselected').create();
      await File('${base.path}/architecture.yaml')
          .copy('${selected.path}/architecture.yaml');
      final alias = Link('${base.path}/selected-link');
      // This fixture setup uses dart:io independently of Archway's bridge.
      // A permission/capability failure here is not a product semantic red.
      await alias.create('\uFEFFselected');
      expect(
        await FileSystemEntity.type(alias.path, followLinks: false),
        FileSystemEntityType.link,
      );
      final expectedRoot = await selected.resolveSymbolicLinks();
      expect(await Directory(alias.path).resolveSymbolicLinks(), expectedRoot);
      print('BOM_ALIAS_FIXTURE_READY relative_target=U+FEFFselected');
      final report = await checkPhysical(Directory(alias.path), 0);
      expect(report['resolved_root'], expectedRoot);
    },
  );

  test(
    'Windows root canonicalization follows an absolute directory symbolic link',
    () async {
      final runnerTemp = Platform.environment['RUNNER_TEMP'];
      final temporary = await physicalFixture(
        '[]',
        '[]',
        base: runnerTemp == null ? null : Directory(runnerTemp),
      );
      final base = Directory(await temporary.resolveSymbolicLinks());
      print('ABSOLUTE_ALIAS_TEST_ROOT=${base.path}');
      final selected = await Directory('${base.path}/selected').create();
      await File('${base.path}/architecture.yaml')
          .copy('${selected.path}/architecture.yaml');
      final expectedRoot = await selected.resolveSymbolicLinks();
      final alias = Link('${base.path}/selected-link');
      // Pinned Dart calls CreateSymbolicLinkW, not junction creation. Verify
      // the actual OS tag independently before attributing failure to the CLI.
      await alias.create(expectedRoot);
      final systemRoot = Platform.environment['SystemRoot'];
      expect(
        systemRoot,
        isNotNull,
        reason: 'System tool location is required.',
      );
      final reparse = await Process.run('$systemRoot/System32/fsutil.exe', [
        'reparsepoint',
        'query',
        alias.path,
      ]);
      expect(
        reparse.exitCode,
        0,
        reason: '${reparse.stdout} ${reparse.stderr}',
      );
      print('ABSOLUTE_ALIAS_REPARSE_DATA=${reparse.stdout}');
      expect(
        reparse.stdout.toString(),
        matches(RegExp(r'0xa000000c\b', caseSensitive: false)),
        reason: 'Require IO_REPARSE_TAG_SYMLINK, not a junction.',
      );
      expect(await Directory(alias.path).resolveSymbolicLinks(), expectedRoot);
      print('ABSOLUTE_ALIAS_FIXTURE_READY tag=0xa000000c');
      final report = await checkPhysical(Directory(alias.path), 0);
      expect(report['resolved_root'], expectedRoot);
    },
    skip: !Platform.isWindows
        ? 'Requires Windows symbolic-link evidence.'
        : false,
  );

  test(
    'Windows root canonicalization follows a local directory junction',
    () async {
      final runnerTemp = Platform.environment['RUNNER_TEMP'];
      final temporary = await physicalFixture(
        '[]',
        '[]',
        base: runnerTemp == null ? null : Directory(runnerTemp),
      );
      final base = Directory(await temporary.resolveSymbolicLinks());
      print('JUNCTION_TEST_ROOT=${base.path}');
      final selected = await Directory('${base.path}/selected target').create();
      await File('${base.path}/architecture.yaml')
          .copy('${selected.path}/architecture.yaml');
      final expectedRoot = await selected.resolveSymbolicLinks();
      // Keep native separators and spaces in the real junction fixture.
      final alias = Link(
        '${base.path}${Platform.pathSeparator}selected junction',
      );
      final systemRoot = Platform.environment['SystemRoot'];
      expect(
        systemRoot,
        isNotNull,
        reason: 'System tool location is required.',
      );
      // Retain the controlled local-path guard for fixture creation.
      for (final path in [alias.path, expectedRoot]) {
        expect(RegExp(r'[&|<>^%!"\r\n]').hasMatch(path), false);
        expect(RegExp(r'^[A-Za-z]:\\').hasMatch(path), true);
      }
      // Use the documented Junction provider operation. EncodedCommand avoids
      // cmd/CRT quoting layers and carries Unicode as UTF-16LE. Single-quoted
      // PowerShell literals escape apostrophes by doubling them.
      final linkLiteral = alias.path.replaceAll("'", "''");
      final targetLiteral = expectedRoot.replaceAll("'", "''");
      final script =
          '''
\$ErrorActionPreference = 'Stop'
try {
  New-Item -ItemType Junction -Path '$linkLiteral' -Target '$targetLiteral' -ErrorAction Stop | Out-Null
  exit 0
} catch {
  [Console]::Error.WriteLine(\$_.Exception.Message)
  exit 1
}
''';
      final encoded = base64Encode([
        for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
      ]);
      print('JUNCTION_CREATE_PATHS=${jsonEncode([alias.path, expectedRoot])}');
      final created = await Process.run(
        '$systemRoot/System32/WindowsPowerShell/v1.0/powershell.exe',
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
      );
      expect(
        created.exitCode,
        0,
        reason: '${created.stdout} ${created.stderr}',
      );
      final reparse = await Process.run('$systemRoot/System32/fsutil.exe', [
        'reparsepoint',
        'query',
        alias.path,
      ]);
      expect(
        reparse.exitCode,
        0,
        reason: '${reparse.stdout} ${reparse.stderr}',
      );
      print('JUNCTION_REPARSE_DATA=${reparse.stdout}');
      expect(
        reparse.stdout.toString(),
        matches(RegExp(r'0xa0000003\b', caseSensitive: false)),
        reason: 'Require IO_REPARSE_TAG_MOUNT_POINT for this local junction.',
      );
      expect(await Directory(alias.path).resolveSymbolicLinks(), expectedRoot);
      print('JUNCTION_FIXTURE_READY tag=0xa0000003');
      final report = await checkPhysical(Directory(alias.path), 0);
      expect(report['resolved_root'], expectedRoot);
    },
    skip: !Platform.isWindows ? 'Requires Windows junction evidence.' : false,
  );

  for (final ancestor in [false, true]) {
    test(
      'a persistent ${ancestor ? "ancestor" : "file"} link inserted after raw tracing is rejected',
      () async {
        final temporary = await physicalFixture('[src/]', '[]');
        // Match the canonical root used by observation, including macOS /var.
        final root = Directory(await temporary.resolveSymbolicLinks());
        final directory = await Directory('${root.path}/src').create();
        final source = await File('${directory.path}/victim.ts')
            .writeAsString('export {};');
        var replaced = false;
        final report = await runZoned(
          () => checkPhysical(root, 2),
          zoneValues: {
            #archwayBeforeObservationCanonical: (String path) {
              if (replaced || File(path).uri != source.uri) return;
              replaced = true;
              final original = ancestor ? directory.path : source.path;
              final moved = '${root.path}/moved';
              if (ancestor) {
                directory.renameSync(moved);
              } else {
                source.renameSync(moved);
              }
              Link(original).createSync(moved);
            },
          },
        );
        expect(replaced, isTrue);
        expect(
          report['payload'].toString(),
          contains('Physical route changed during canonicalization'),
        );
        expect(report['payload']['analysis_complete'], isFalse);
        expect(
          (report['payload']['unknowns'] as List).map((d) => d['code']),
          contains('CORPUS_ENUMERATION_FAILED'),
        );
      },
    );
  }

  test(
    'case-insensitive source lookup does not relax exact scope spelling',
    () async {
      final root = await physicalFixture('[case.ts]', '[]');
      await File('${root.path}/Case.ts').writeAsString('export {};');
      if (!await File('${root.path}/case.ts').exists()) {
        markTestSkipped('Requires a case-insensitive filesystem.');
        return;
      }
      final report = await checkPhysical(root, 2);
      expect(report['payload']['analysis_complete'], isFalse);
      expect(
        (report['payload']['unknowns'] as List).map((d) => d['code']),
        contains('PHYSICAL_PATH_AMBIGUOUS'),
      );
    },
  );

  test('a listed file replaced by an empty directory cannot certify an empty corpus', () async {
    final root = await physicalFixture('[./]', '[]');
    final source = File('${root.path}/victim.ts');
    await source.writeAsString('export {};');
    var replaced = false;
    final report = await runZoned(
      () => checkPhysical(root, 2),
      zoneValues: {
        #archwayBeforeInventoryEntryStat: (String path) {
          if (!replaced && File(path).uri == source.uri) {
            replaced = true;
            source.deleteSync();
            Directory(path).createSync();
          }
        },
      },
    );
    expect(report['status'], 'incomplete');
    expect(report['payload']['analysis_complete'], false);
    expect(
      (report['payload']['unknowns'] as List).map((d) => d['code']),
      contains('CORPUS_ENUMERATION_FAILED'),
    );
  });

  test(
    'a directory entry disappearing before stat is an enumeration gap',
    () async {
      final root = await physicalFixture('[./]', '[]');
      final source = File('${root.path}/gone.ts');
      await source.writeAsString('export {};');
      final report = await runZoned(
        () => checkPhysical(root, 2),
        zoneValues: {
          #archwayBeforeInventoryEntryStat: (String path) {
            if (File(path).uri == source.uri && source.existsSync())
              source.deleteSync();
          },
        },
      );
      expect(
        (report['payload']['unknowns'] as List).map((d) => d['code']),
        contains('CORPUS_ENUMERATION_FAILED'),
      );
    },
  );

  test('a stable policy alias retains its physical input identity', () async {
    final root = await physicalFixture('[]', '[]');
    await File('${root.path}/architecture.yaml')
        .rename('${root.path}/policy.actual.yaml');
    await Link('${root.path}/architecture.yaml').create('policy.actual.yaml');
    final report = await checkPhysical(root, 0);
    expect(
      report['payload']['input_identity']['aliases'],
      contains(
        equals({
          'observed_file_uri': File('${root.path}/architecture.yaml').uri
              .toString(),
          'canonical_file_uri': File('${root.path}/policy.actual.yaml').uri
              .toString(),
        }),
      ),
    );
  });

  test(
    'an exact NFC scope cannot hide a differently normalized physical entry',
    () async {
      final root = await physicalFixture('[é.ts]', '[]');
      await File('${root.path}/e\u0301.ts').writeAsString('export {};');
      final report = await checkPhysical(root, 2);
      expect(report['status'], 'incomplete');
      expect(
        (report['payload']['unknowns'] as List).single['code'],
        'PHYSICAL_PATH_AMBIGUOUS',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'included file and directory links never certify an empty corpus',
    () async {
      for (final scope in ['[link.ts]', '[linked/]', '[linked/nested.ts]']) {
        final root = await physicalFixture(scope, '[]');
        await Link('${root.path}/link.ts').create('absent.ts');
        await Link('${root.path}/linked').create('absent-directory');
        final report = await checkPhysical(root, 2);
        expect(report['status'], 'incomplete');
        expect(report['payload']['observed']['files'], 0);
        expect(
          (report['payload']['unknowns'] as List).single['code'],
          'SOURCE_SYMLINK',
        );
      }
    },
  );

  test(
    'an excluded cyclic alias under a selected directory stays untraversed',
    () async {
      final root = await physicalFixture('[./]', '[ignored/]');
      await Link('${root.path}/ignored').create('ignored');
      final report = await checkPhysical(root, 0);
      expect(report['payload']['unknowns'], isEmpty);
      expect(report['payload']['input_identity']['aliases'], isEmpty);
    },
  );

  test('unrepresentable and non-NFC entries are incomplete without a global failure', () async {
    for (final name in [
      'bad*.dart',
      'bad[1].ts',
      'CON.ts',
      'bad .ts.',
      'e\u0301.ts',
    ]) {
      final root = await physicalFixture('[./]', '[]');
      await File('${root.path}/$name').writeAsString('');
      final report = await checkPhysical(root, 2);
      expect(report['status'], 'incomplete', reason: name);
      expect(report['payload']['unknowns'], isNotEmpty);
    }
  }, skip: Platform.isWindows);

  test('a literal POSIX backslash filename cannot become a clean absent portable path', () async {
    final root = await physicalFixture('[./]', '[]');
    await File('${root.path}/bad\\name.ts').writeAsString('export {};');
    final report = await checkPhysical(root, 2);
    expect(report['status'], 'incomplete');
    expect(report['payload']['analysis_complete'], false);
    expect(report['payload']['unknowns'], isNotEmpty);
    expect(report['payload']['unknowns'][0]['path'], isNull);
    expect(
      report['payload']['unknowns'][0]['message'],
      contains('bad\\name.ts'),
    );
  }, skip: Platform.isWindows);

  test('an explicitly excluded scope alias is skipped without resolving its target', () async {
    final root = await physicalFixture('[ignored/]', '[ignored/]');
    await Link('${root.path}/ignored').create('missing');
    final report = await checkPhysical(root, 0);
    expect(report['status'], 'ok');
    expect(report['payload']['analysis_complete'], true);
    expect(report['payload']['observed'], {
      'files': 0,
      'analyzed_files': 0,
      'edges': 0,
    });
    expect(report['payload']['unknowns'], isEmpty);
    expect(report['payload']['input_identity']['aliases'], isEmpty);
  });
}
