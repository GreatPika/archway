// Real filesystem/archive assembly with explicitly synthetic host receipts.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../tool/release/installation_identity.dart';
import 'finalizer_receipt_fixtures.dart';
import 'installed_route_receipt_fixtures.dart';

class ReleaseFinalizerFixture {
  final root = Directory.systemTemp.createTempSync('release-finalizer-');
  late final repository = Directory(p.join(root.path, 'source'))..createSync();
  late final release = Directory(p.join(root.path, 'release'))..createSync();
  late final reports = Directory(p.join(root.path, 'reports'))..createSync();
  late final installed = Directory(p.join(root.path, 'installed'));
  late final output = Directory(p.join(root.path, 'final'));
  late Map<String, Object> source;
  late Map<String, dynamic> transport;
  Future<void> prepare({
    bool registryReady = false,
    String sourceVersion = '0.1.0',
  }) async {
    final tracked = {
      'pubspec.yaml': 'name: archway\nversion: $sourceVersion\n',
      'pubspec.lock': 'locked\n',
      'assets/typescript/package-lock.json': 'locked npm\n',
      'test/example_test.dart': 'synthetic source\n',
    };
    for (final entry in tracked.entries) {
      final file = File(p.join(repository.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    void git(List<String> args) {
      final result = Process.runSync('git', ['-C', repository.path, ...args]);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
    }

    git(['init', '--quiet', '--template=']);
    git(['add', '.']);
    git([
      '-c',
      'user.name=Receipt fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '--quiet',
      '-m',
      'Synthetic receipt source',
    ]);
    source = await sourceIdentity(repository);
    final snapshot = {
      for (final entry in tracked.entries)
        entry.key: hash(utf8.encode(entry.value)),
    };
    for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
      final f = FinalizerReceiptFixture(
        target,
        identity: source,
        snapshot: snapshot,
      );
      try {
        f.archiveFile.copySync(
          p.join(release.path, p.basename(f.archiveFile.path)),
        );
        final directory = Directory(p.join(reports.path, target))..createSync();
        for (final entity in f.root.listSync(recursive: true)) {
          if (entity is! File || p.isWithin(f.release.path, entity.path))
            continue;
          final relative = p.relative(entity.path, from: f.root.path);
          final file = File(
            p.join(
              directory.path,
              relative == 'native.json' ? 'report.json' : relative,
            ),
          );
          file.parent.createSync(recursive: true);
          entity.copySync(file.path);
        }
      } finally {
        f.close();
      }
    }
    for (final name in ['public-result', 'export-diagnostics']) {
      final file = File(
        p.join(repository.path, 'contracts/json/$name.schema.json'),
      );
      file.parent.createSync(recursive: true);
      File('contracts/json/$name.schema.json').copySync(file.path);
    }
    final npm = File(p.join(release.path, 'archway-architecture-cli-0.1.0.tgz'))
      ..writeAsStringSync('SYNTHETIC NPM FIXTURE');
    File(p.join(release.path, 'QUICKSTART.txt'))
        .writeAsStringSync('Synthetic fixture only\n');
    final evidence = archive.Archive()
      ..addFile(
        archive.ArchiveFile.string(
          'release-packaging.json',
          jsonEncode({'source': source}),
        )..mode = 0x81a4,
      )
      ..addFile(
        archive.ArchiveFile.string(
          'original-proof.txt',
          'Synthetic original evidence',
        )..mode = 0x81a4,
      );
    File(p.join(release.path, 'archway-0.1.0-evidence.zip'))
        .writeAsBytesSync(archive.ZipEncoder().encode(evidence));
    final files = release.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    File(p.join(release.path, 'SHA256SUMS')).writeAsStringSync(
      files
          .map(
            (file) =>
                '${hash(file.readAsBytesSync())}  ${p.basename(file.path)}\n',
          )
          .join(),
    );
    transport = installedRouteFixture(
      installed,
      source,
      hash(npm.readAsBytesSync()),
      registryReady: registryReady,
    );
  }

  static String hash(List<int> bytes) => sha256.convert(bytes).toString();
  void close() => root.deleteSync(recursive: true);
}
