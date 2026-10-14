import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/finalize_release_evidence.dart';
import '../tool/release/archive_input.dart';
import '../tool/release/zip_input.dart';
import 'release_finalizer_fixtures.dart';

void main() {
  test('combined evidence rejects portable collisions and aggregate entry overflow', () async {
    final f = ReleaseFinalizerFixture();
    addTearDown(f.close);
    await f.prepare();
    const name = 'archway-0.1.0-evidence.zip';
    final evidence = File(p.join(f.release.path, name));
    final original = evidence.readAsBytesSync();
    final sums = File(p.join(f.release.path, 'SHA256SUMS'));
    final originalSums = sums.readAsStringSync();
    for (final collision in [
      'native-smoke',
      'Native-Smoke/original.txt',
      'entry-bound',
    ]) {
      final contents = ZipDecoder().decodeBytes(original);
      if (collision == 'entry-bound') {
        for (var i = contents.files.length; i < maxArchiveEntries; i++) {
          contents.addFile(
            ArchiveFile.bytes('original-$i.txt', <int>[])..mode = 0x81a4,
          );
        }
      } else {
        contents.addFile(ArchiveFile.bytes(collision, [42])..mode = 0x81a4);
      }
      evidence.writeAsBytesSync(ZipEncoder().encode(contents));
      sums.writeAsStringSync(
        originalSums.replaceAll(
          ReleaseFinalizerFixture.hash(original),
          ReleaseFinalizerFixture.hash(evidence.readAsBytesSync()),
        ),
      );
      // Each original is independently valid; only the combined inventory fails.
      await withArchiveInput(evidence.absolute, readZipFiles);
      await expectLater(
        finalizeRelease(
          release: f.release,
          reports: f.reports,
          output: f.output,
          expectedCommit: f.source['commit'] as String,
          repository: f.repository,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'combined inventory',
            contains(
              collision == 'entry-bound'
                  ? 'entry bound'
                  : 'Aliased or colliding archive path',
            ),
          ),
        ),
      );
      expect(f.output.existsSync(), isFalse);
      expect(
        f.root.listSync().where(
          (e) => p.basename(e.path).startsWith('.archway-final-'),
        ),
        isEmpty,
      );
    }
  });
  test(
    'finalization preserves payloads and emits complete unique byte checksums',
    () async {
      final f = ReleaseFinalizerFixture();
      addTearDown(f.close);
      await f.prepare();
      // Match upload-artifact common-root layout: fixtures are outside the report directory.
      for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
        final root = p.join(f.reports.path, target);
        final nested = p.join(root, 'workspace/build/release-native');
        Directory(nested).createSync(recursive: true);
        for (final name in ['acceptance', 'installer']) {
          Directory(p.join(root, name)).renameSync(p.join(nested, name));
        }
        File(p.join(root, 'report.json'))
            .renameSync(p.join(nested, 'report.json'));
      }
      await finalizeRelease(
        release: f.release,
        reports: f.reports,
        output: f.output,
        expectedCommit: f.source['commit'] as String,
        repository: f.repository,
      );
      final names = f.output.listSync().map((e) => p.basename(e.path)).toSet();
      final lines = const LineSplitter().convert(
        File(p.join(f.output.path, 'SHA256SUMS')).readAsStringSync(),
      );
      expect(lines, isNotEmpty);
      final checksums = <String, String>{};
      for (final line in lines) {
        final fields = line.split('  ');
        expect(fields, hasLength(2));
        expect(
          checksums.containsKey(fields[1]),
          isFalse,
          reason: 'duplicate checksum name',
        );
        checksums[fields[1]] = fields[0];
      }
      expect(checksums.keys.toSet(), names.difference({'SHA256SUMS'}));
      for (final entry in checksums.entries) {
        expect(
          entry.value,
          ReleaseFinalizerFixture.hash(
            File(p.join(f.output.path, entry.key)).readAsBytesSync(),
          ),
        );
      }
      for (final file in f.release.listSync().whereType<File>()) {
        if ([
          'SHA256SUMS',
          'archway-0.1.0-evidence.zip',
        ].contains(p.basename(file.path)))
          continue;
        expect(
          File(p.join(f.output.path, p.basename(file.path))).readAsBytesSync(),
          file.readAsBytesSync(),
        );
      }
      for (final entry in {
        'linux-x64': 'deb',
        'macos-arm64': 'pkg',
        'windows-x64': 'exe',
      }.entries) {
        expect(
          names,
          contains('archway-0.1.0-${entry.key}-unsigned.${entry.value}'),
        );
      }
      await withArchiveInput(
        File(p.join(f.output.path, 'archway-0.1.0-evidence.zip')).absolute,
        readZipFiles,
      );
      final evidence = ZipDecoder().decodeBytes(
        File(p.join(f.output.path, 'archway-0.1.0-evidence.zip'))
            .readAsBytesSync(),
      );
      expect(
        utf8.decode(evidence.findFile('original-proof.txt')!.content),
        'Synthetic original evidence',
      );
      expect(
        evidence.files.map((e) => e.name),
        contains('native-smoke/windows-x64.json'),
      );
      expect(
        evidence.files.any(
          (e) => ['.deb', '.pkg', '.exe'].contains(p.extension(e.name)),
        ),
        isFalse,
      );
    },
  );
  test(
    'installed finalization binds every route and retains original evidence',
    () async {
      final f = ReleaseFinalizerFixture();
      addTearDown(f.close);
      await f.prepare(registryReady: true);
      Future<void> run(Directory output) => finalizeRelease(
        release: f.release,
        reports: f.reports,
        output: output,
        expectedCommit: f.source['commit'] as String,
        repository: f.repository,
        installedEvidence: f.installed,
        registryReady: true,
        runId: '123',
        runAttempt: '1',
        expectedTransportJson: jsonEncode(f.transport),
      );
      await run(f.output);
      final evidence = ZipDecoder().decodeBytes(
        File(p.join(f.output.path, 'archway-0.1.0-evidence.zip'))
            .readAsBytesSync(),
      );
      const name = 'npm/npm-installed-local-linux-x64-123-1/report.json';
      expect(
        evidence.findFile('installed-routes/$name')!.content,
        File(p.join(f.installed.path, name)).readAsBytesSync(),
      );
      final selected = File(p.join(f.installed.path, name));
      final original = selected.readAsStringSync();
      for (final entry in {
        'source_commit': '0' * 40,
        'run_id': '124',
        'run_attempt': '2',
        'tarball_sha256': '0' * 64,
        'target': 'macos-arm64',
        'route': 'global-prefix',
      }.entries) {
        final changed = jsonDecode(original) as Map;
        changed[entry.key] = entry.value;
        selected.writeAsStringSync(jsonEncode(changed));
        final output = Directory(p.join(f.root.path, 'wrong-${entry.key}'));
        await expectLater(run(output), throwsFormatException);
        expect(output.existsSync(), isFalse);
      }
      selected.writeAsStringSync('not JSON');
      await expectLater(
        run(Directory(p.join(f.root.path, 'bad-json'))),
        throwsFormatException,
      );
      selected.deleteSync();
      await expectLater(
        run(Directory(p.join(f.root.path, 'missing-report'))),
        throwsFormatException,
      );
      selected.writeAsStringSync(original);
      final pub = File(
        p.join(
          f.installed.path,
          'pub/pub-installed-linux-x64-123-1/nested/report.json',
        ),
      );
      final pubOriginal = pub.readAsStringSync();
      final legacy = jsonDecode(pubOriginal) as Map;
      legacy['phases']['snapshot_only'] = legacy['phases'].remove(
        'poisoned_source_snapshot',
      );
      pub.writeAsStringSync(jsonEncode(legacy));
      await expectLater(
        run(Directory(p.join(f.root.path, 'legacy-phase'))),
        throwsFormatException,
      );
      pub.writeAsStringSync(pubOriginal);
      final changed = jsonDecode(pubOriginal) as Map;
      changed['transport']['upload_archive']['sha256'] = '0' * 64;
      pub.writeAsStringSync(jsonEncode(changed));
      await expectLater(
        run(Directory(p.join(f.root.path, 'wrong-transport'))),
        throwsFormatException,
      );
      expect(
        f.root.listSync().whereType<Directory>().map((d) => p.basename(d.path)),
        unorderedEquals(['source', 'release', 'reports', 'installed', 'final']),
      );
    },
  );
  test('refuses wrong archive, extra installer and existing output without publication', () async {
    final f = ReleaseFinalizerFixture();
    addTearDown(f.close);
    await f.prepare();
    Future<void> run({bool registryReady = false}) => finalizeRelease(
      release: f.release,
      reports: f.reports,
      output: f.output,
      expectedCommit: f.source['commit'] as String,
      repository: f.repository,
      registryReady: registryReady,
    );
    await expectLater(run(registryReady: true), throwsFormatException);
    expect(f.output.existsSync(), isFalse);
    final report = File(p.join(f.reports.path, 'linux-x64/report.json'));
    final saved = report.readAsStringSync();
    final wrong = jsonDecode(saved) as Map;
    wrong['archive_sha256'] = '0' * 64;
    report.writeAsStringSync(jsonEncode(wrong));
    await expectLater(run(), throwsFormatException);
    expect(f.output.existsSync(), isFalse);
    report.writeAsStringSync(saved);
    final extra = File(
      p.join(f.reports.path, 'linux-x64/installer/test-only-old.deb'),
    )..writeAsStringSync('must not enter evidence');
    await expectLater(
      run(),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected installer binary'),
        ),
      ),
    );
    expect(f.output.existsSync(), isFalse);
    extra.deleteSync();
    expect(
      f.root.listSync().where(
        (e) => p.basename(e.path).startsWith('.archway-final-'),
      ),
      isEmpty,
    );
    f.output.createSync();
    final sentinel = File(p.join(f.output.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    await expectLater(run(), throwsFormatException);
    expect(sentinel.readAsStringSync(), 'keep');
  });
  test(
    'CLI refuses missing registry receipts with original diagnostic',
    () async {
      final f = ReleaseFinalizerFixture();
      addTearDown(f.close);
      await f.prepare();
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('tool/ci/finalize_release_evidence.dart').absolute.path,
        '--release-directory',
        f.release.path,
        '--reports',
        f.reports.path,
        '--output',
        f.output.path,
        '--expected-commit',
        f.source['commit'] as String,
        '--registry-ready',
      ], workingDirectory: f.repository.path);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Release finalization refused:'));
      expect(result.stderr, contains('requires installed receipts'));
      expect(result.stdout, isEmpty);
      expect(f.output.existsSync(), isFalse);
    },
  );
}
