// Compose independent original evidence fixtures for aggregate admission.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import 'installed_receipt_fixtures.dart';
import 'native_acceptance_receipt_fixtures.dart' as native;
import 'native_installer_receipt_fixtures.dart';
import 'source_receipt_fixtures.dart' as source;

class FinalizerReceiptFixture {
  FinalizerReceiptFixture(
    this.target, {
    Map<String, Object?>? identity,
    Map<String, String>? snapshot,
  }) {
    nativeEvidence = native.Evidence(target);
    sourceEvidence = source.Fixture(target);
    if (identity != null) {
      sourceEvidence.proof['source'] = identity;
      sourceEvidence.source['source'] = identity;
    }
    if (snapshot != null) sourceEvidence.rewriteSnapshot(jsonEncode(snapshot));
    installerEvidence = InstallerEvidence(target);
    addInstalledReceipts(installerEvidence);
    nativeEvidence.source
      ..clear()
      ..addAll(sourceEvidence.proof['source'] as Map<String, Object?>);
    final acceptance = nativeEvidence.acceptance;
    final fixtures = nativeEvidence.fixture;
    final oldFixtures =
        sourceEvidence.proof['acceptance']['fixtures']['manifest'] as Map;
    final replacements = <String, String>{
      oldFixtures['dart_sdk'] as String: fixtures['dart_sdk'] as String,
      installerEvidence.at('dart_sdk'): fixtures['dart_sdk'] as String,
      installerEvidence.at('repo'): acceptance['source_root'] as String,
      installerEvidence.at('node'): acceptance['node_path'] as String,
      installerEvidence.at('acceptance'): acceptance['output_root'] as String,
      installerEvidence.at('relocated café installation'):
          (nativeEvidence.proof['relocation'] as Map)['executed'] as String,
      installerEvidence.at('installer'): nativeEvidence.paths.join(
        nativeEvidence.paths.dirname(acceptance['output_root'] as String),
        'installer',
      ),
    };
    String replace(String text) {
      for (final entry in replacements.entries) {
        text = text.replaceAll(entry.key, entry.value);
      }
      return text;
    }

    Object? rewrite(Object? value) => switch (value) {
      String() => replace(value),
      Map() => value.map(
        (key, value) => MapEntry(key as String, rewrite(value)),
      ),
      List() => value.map(rewrite).toList(),
      _ => value,
    };
    final sourceRecord = rewrite(sourceEvidence.source) as Map<String, dynamic>;
    acceptance['source_suite'] = sourceRecord;
    final installer =
        rewrite(installerEvidence.receipt) as Map<String, dynamic>;
    // Old build operands bind the same independently supplied source commit.
    for (final command in installer['commands'] as List) {
      command['arguments'] = (command['arguments'] as List)
          .map(
            (value) =>
                value == 'f' * 40 ? nativeEvidence.source['commit'] : value,
          )
          .toList();
    }
    nativeEvidence.proof['installer'] = installer;
    void copy(Directory from, Directory to) {
      for (final entity in from.listSync(recursive: true)) {
        if (entity is! File) continue;
        final file = File(
          p.join(to.path, p.relative(entity.path, from: from.path)),
        );
        file.parent.createSync(recursive: true);
        if (entity.path.endsWith('.json')) {
          file.writeAsStringSync(
            jsonEncode(rewrite(jsonDecode(entity.readAsStringSync()))),
          );
        } else if (entity.path.endsWith('.log')) {
          file.writeAsStringSync(replace(entity.readAsStringSync()));
        } else {
          file.writeAsBytesSync(entity.readAsBytesSync());
        }
      }
    }

    copy(sourceEvidence.evidence, nativeEvidence.directory);
    final installerDirectory = Directory(
      p.join(nativeEvidence.root.path, 'installer'),
    );
    copy(installerEvidence.directory, installerDirectory);
    // Changed recorded paths change original stream bytes and their receipts together.
    for (final command in installer['commands'] as List) {
      for (final stream in ['stdout', 'stderr']) {
        command['${stream}_sha256'] = hash(
          File(p.join(installerDirectory.path, command[stream] as String))
              .readAsBytesSync(),
        );
      }
    }
    for (final key in ['preparation', 'execution']) {
      File(
        p.join(
          nativeEvidence.directory.path,
          '${sourceRecord[key]['suite']}.json',
        ),
      ).writeAsStringSync(jsonEncode(sourceRecord[key]));
    }
    release = Directory(p.join(root.path, 'release'))..createSync();
    final payloads = <String, List<int>>{
      'assets/typescript/vendor/typescript.js': utf8.encode('vendor'),
      'native/$target/library': utf8.encode('native'),
    };
    final manifest = {
      'source': nativeEvidence.source,
      'target': target,
      'files': {
        for (final entry in payloads.entries)
          entry.key: {
            'size': entry.value.length,
            'mode': 0x1a4,
            'sha256': hash(entry.value),
          },
      },
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    installer['bundle_manifest_sha256'] = hash(manifestBytes);
    installer['installed']['manifest_sha256'] = hash(manifestBytes);
    payloads['manifest.json'] = manifestBytes;
    final filename =
        'archway-0.1.0-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
    final zip = archive.Archive();
    for (final entry in payloads.entries) {
      zip.addFile(
        archive.ArchiveFile(entry.key, entry.value.length, entry.value)
          ..mode = 0x81a4,
      );
    }
    for (final name in ['public-result', 'export-diagnostics']) {
      final file = File(
        p.join(sourceEvidence.repo.path, 'contracts/json/$name.schema.json'),
      );
      file.parent.createSync(recursive: true);
      File('contracts/json/$name.schema.json').copySync(file.path);
    }
    final bytes = target == 'windows-x64'
        ? archive.ZipEncoder().encode(zip)
        : gzip.encode([
            for (final entry in payloads.entries)
              ...tarConverter
                  .convert(
                    TarEntry.data(
                      TarHeader(name: entry.key, mode: 0x1a4),
                      entry.value,
                    ),
                  )
                  .take(512 + ((entry.value.length + 511) ~/ 512) * 512),
            ...List.filled(1024, 0),
          ]);
    archiveFile = File(p.join(release.path, filename))..writeAsBytesSync(bytes);
    nativeEvidence.proof.addAll({
      'ci_host_verified': true,
      'archive': filename,
      'archive_sha256': hash(bytes),
      'native_commands': ['help', 'version', 'init', 'validate', 'export'],
      'typescript': [
        for (final entry in const {
          'clean': 0,
          'dependency-violation': 1,
          'unsupported-option': 64,
          'missing-owned-helper': 2,
          'restored-clean': 0,
        }.entries)
          {
            'case': entry.key,
            'exit': entry.value,
            'command': 'check',
            'status': entry.value == 0
                ? 'ok'
                : entry.value == 1
                ? 'negative'
                : entry.value == 64
                ? 'usage_error'
                : 'incomplete',
            'analysis_complete': entry.value == 64 ? null : entry.value != 2,
          },
      ],
    });
    nativeEvidence.saveFixture();
    save();
  }
  final String target;
  late final native.Evidence nativeEvidence;
  late final source.Fixture sourceEvidence;
  late final InstallerEvidence installerEvidence;
  late final Directory release;
  late final File archiveFile;
  Directory get root => nativeEvidence.root;
  Map<String, Object?> get proof => nativeEvidence.proof;
  static String hash(List<int> bytes) => sha256.convert(bytes).toString();
  void save() => nativeEvidence.report.writeAsStringSync(jsonEncode(proof));
  void close() {
    nativeEvidence.root.deleteSync(recursive: true);
    sourceEvidence.close();
    installerEvidence.root.deleteSync(recursive: true);
  }
}
