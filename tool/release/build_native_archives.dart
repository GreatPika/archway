// Build native release archives before package staging; never publish a release.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as zip;
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import '../validation/json_values.dart';
import '../ci/native_assembly_init_probe.dart' show verifyAssembly;
import 'archive_input.dart';
import 'installation_identity.dart';
import 'native_archive.dart';
import 'native_manifest.dart';
import 'native_payload.dart';
import 'publish_directory.dart';
import 'tar_input.dart';

Future<void> main(List<String> arguments) async {
  try {
    const names = {
      '--source',
      '--transports',
      '--guide',
      '--expected-commit',
      '--output',
    };
    final options = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      requireNative(
        names.contains(arguments[i]) &&
            i + 1 < arguments.length &&
            !options.containsKey(arguments[i]),
        'Expected --source DIR --transports DIR --guide FILE --expected-commit SHA --output NEW_DIR',
      );
      options[arguments[i]] = arguments[i + 1];
    }
    requireNative(
      options.length == names.length,
      'Missing native producer option',
    );
    await buildNativeArchives(
      Directory(options['--source']!).absolute,
      Directory(options['--transports']!).absolute,
      File(options['--guide']!).absolute,
      options['--expected-commit']!,
      Directory(options['--output']!).absolute,
    );
  } catch (error) {
    stderr.writeln('Native archive production refused: $error');
    exitCode = 1;
  }
}

Future<void> buildNativeArchives(
  Directory source,
  Directory transports,
  File guide,
  String expectedCommit,
  Directory output,
) async {
  requireNative(
    await FileSystemEntity.type(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Native output already exists',
  );
  final identity = await sourceIdentity(source);
  requireNative(
    identity['commit'] == expectedCommit,
    'Source differs from expected commit',
  );
  await output.parent.create(recursive: true);
  final stage = await output.parent.createTemp('.archway-native-');
  var published = false;
  try {
    final records = <String, Map<String, Object?>>{};
    final evidence = Directory(p.join(stage.path, 'evidence'))..createSync();
    for (final target in nativeTargets.keys) {
      final original = Directory(p.join(evidence.path, 'original', target))
        ..createSync(recursive: true);
      for (final name in ['provenance.json', 'installation.tar']) {
        await withArchiveInput(
          File(p.join(transports.path, target, name)),
          (input) async {
            await input.file.copy(p.join(original.path, name));
          },
          maxBytes: name.endsWith('.json')
              ? maxArchiveJsonBytes
              : maxArchiveBytes,
        );
      }
      final record = await readNativeJson(
        File(p.join(original.path, 'provenance.json')),
      );
      requireNative(
        record['schema_version'] == 1 &&
            record['target'] == target &&
            sameJson(record['source'], identity),
        'Transport source or target mismatch',
      );
      requireNative(
        record.length == 8 &&
            {
              'schema_version',
              'source',
              'target',
              'host',
              'checks',
              'runtimes',
              'files',
              'archive',
            }.every(record.containsKey),
        'Invalid transport record shape',
      );
      final host = record['host'] as Map;
      requireNative(
        host.length == 3 &&
            {'system', 'machine', 'release'}.every(host.containsKey),
        'Invalid transport host shape',
      );
      records[target] = record;
    }
    // Reuse the existing transport receipt/host/shared-asset audit against only
    // owned snapshots, so later parsing never reopens caller-owned evidence.
    final audit = await Process.run(Platform.resolvedExecutable, [
      p.join(
        File.fromUri(Platform.script).parent.parent.path,
        'ci/audit_installation_transports.dart',
      ),
      '--expected-commit',
      expectedCommit,
      '--report',
      p.join(evidence.path, 'transport-audit.json'),
      for (final target in nativeTargets.keys)
        p.join(evidence.path, 'original', target),
    ], workingDirectory: source.path);
    requireNative(
      audit.exitCode == 0,
      'Transport audit failed: ${audit.stderr}',
    );
    String runtime(String text, String prefix) {
      final match = RegExp(
        '^${RegExp.escape(prefix)}(\\d+\\.\\d+\\.\\d+)(?:[ \\r\\n]|\$)',
      ).firstMatch(text);
      requireNative(match != null, 'Invalid observed runtime: $text');
      return match!.group(1)!;
    }

    final dartVersions = <String>{}, nodeVersions = <String>{};
    for (final entry in records.entries) {
      final runtimes = entry.value['runtimes'] as Map;
      final expectedRuntimes = {
        'build_dart',
        if (entry.key != 'windows-x64') ...['analysis_dart', 'analysis_node'],
      };
      requireNative(
        runtimes.length == expectedRuntimes.length &&
            expectedRuntimes.every(runtimes.containsKey) &&
            runtimes.values.every(
              (value) =>
                  value is String && value.isNotEmpty && value.length <= 512,
            ),
        'Invalid transport runtime evidence',
      );
      dartVersions.add(
        runtime(runtimes['build_dart'] as String, 'Dart SDK version: '),
      );
      if (entry.key != 'windows-x64') {
        nodeVersions.add(runtime(runtimes['analysis_node'] as String, 'v'));
        requireNative(
          runtime(runtimes['analysis_dart'] as String, 'Dart SDK version: ') ==
              runtime(runtimes['build_dart'] as String, 'Dart SDK version: '),
          'Analysis Dart differs from build runtime',
        );
      }
    }
    requireNative(
      dartVersions.length == 1 && nodeVersions.length == 1,
      'Transport runtime identities disagree',
    );
    final versions = await nativeVersions(
      source,
      dartVersions.single,
      nodeVersions.single,
    );
    final sourceFiles = await sourceNativeAssets(source);
    final additions = <String, File>{};
    final additionsRoot = Directory(p.join(stage.path, '.additions'))
      ..createSync();
    Future<void> add(String name, File file) async {
      final destination = File(p.join(additionsRoot.path, name));
      destination.parent.createSync(recursive: true);
      await withArchiveInput(file, (input) async {
        await input.file.copy(destination.path);
      }, maxBytes: name == 'README.txt' ? 128 * 1024 : maxArchiveFileBytes);
      additions[name] = destination;
    }

    await add('README.txt', guide);
    utf8.decode(await additions['README.txt']!.readAsBytes());
    for (final name in sourceFiles.keys.where(
      (name) => name == 'LICENSE' || name.startsWith('contracts/json/'),
    )) {
      await add(
        name == 'LICENSE' ? name : 'schemas/${p.posix.basename(name)}',
        File(p.join(source.path, name)),
      );
    }
    final bundles = <String, Object?>{};
    for (final target in nativeTargets.keys) {
      final record = records[target]!;
      final files = Map<String, Object?>.from(record['files'] as Map);
      final added = <String, Object?>{};
      for (final entry in additions.entries) {
        added[entry.key] = await withArchiveInput(
          entry.value,
          (input) async => {
            'size': input.size,
            'sha256': input.sha256,
            'mode': 0x1a4,
          },
        );
      }
      final manifest = <String, Object?>{
        'schema_version': 1,
        'version': versions['archway'],
        'target': target,
        'versions': versions,
        'source': identity,
        'original_archive': record['archive'],
        'files': {...files, ...added},
        'scope': 'Release packaging integrity; not a signature or platform certification',
      };
      await validateNativePayload(
        manifest,
        source,
        target: target,
        version: versions['archway']!,
        identity: identity,
      );
      final manifestBytes = utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      );
      final inventory = parseNativeManifest(manifestBytes)
          .completeArchiveInventory;
      final transportInventory = parseNativeManifest(
        utf8.encode(jsonEncode({'files': files})),
      ).completeArchiveInventory.files;
      final archiveName =
          'archway-${versions['archway']}-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
      final destination = File(p.join(stage.path, archiveName));
      await withArchiveInput(
        File(p.join(evidence.path, 'original', target, 'installation.tar')),
        (input) async {
          requireNative(
            sameJson(record['archive'], {
              'name': 'installation.tar',
              'sha256': input.sha256,
            }),
            'Transport archive identity changed',
          );
          await withTarExtraction(
            input,
            ArchiveInventory(
              Map.of(transportInventory)..remove('manifest.json'),
            ),
            (bundle) async {
              verifyAssembly(
                bundle,
                Directory(p.join(source.path, 'assets/typescript')),
                target,
                nativeTargets[target]!.$2,
              );
              for (final package in ['typescript', 'yaml']) {
                final metadata = await readNativeJson(
                  File(
                    p.join(
                      bundle.path,
                      'assets/typescript/vendor',
                      package,
                      'package.json',
                    ),
                  ),
                );
                requireNative(
                  metadata['version'] == versions[package],
                  'Prepared vendor version differs from source: $package',
                );
              }
              for (final entry in additions.entries) {
                final target = File(p.join(bundle.path, entry.key));
                target.parent.createSync(recursive: true);
                await entry.value.copy(target.path);
              }
              await File(p.join(bundle.path, 'manifest.json'))
                  .writeAsBytes(manifestBytes);
              await _writeArchive(
                bundle,
                destination,
                inventory,
                target == 'windows-x64',
              );
            },
          );
        },
      );
      final verified = await verifyNativeArchive(
        destination,
        format: target == 'windows-x64'
            ? NativeArchiveFormat.zip
            : NativeArchiveFormat.tarGzip,
      );
      bundles[target] = {
        'filename': archiveName,
        'size': verified.archiveSize,
        'sha256': verified.archiveSha256,
        'manifest_sha256': verified.manifestSha256,
        'original_archive': record['archive'],
        'added_files': {
          ...added,
          'manifest.json': {
            'size': manifestBytes.length,
            'sha256': verified.manifestSha256,
            'mode': 0x1a4,
          },
        },
      };
    }
    await additionsRoot.delete(recursive: true);
    await File(p.join(stage.path, 'native-packaging.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'version': versions['archway'], 'source': identity, 'native_bundles': bundles})}\n',
    );
    final checksums = <String, String>{
      for (final value in bundles.values)
        (value as Map)['filename'] as String: value['sha256'] as String,
    };
    final names = checksums.keys.toList()..sort();
    await File(
      p.join(stage.path, 'SHA256SUMS'),
    ).writeAsString(names.map((name) => '${checksums[name]}  $name\n').join());
    requireNative(
      sameJson(await sourceIdentity(source), identity),
      'Source changed during native production',
    );
    publishDirectory(stage, output);
    published = true;
    stdout.writeln(
      'Prepared ${output.path}; no publication or host certification performed.',
    );
  } finally {
    if (!published) await stage.delete(recursive: true);
  }
}

Future<void> _writeArchive(
  Directory root,
  File destination,
  ArchiveInventory inventory,
  bool windows,
) async {
  final entries = inventory.files.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  if (windows) {
    final output = zip.OutputFileStream(destination.path);
    try {
      final encoder = zip.ZipEncoder()
        ..startEncode(output, modified: DateTime.utc(1980));
      for (final entry in entries) {
        // One bounded file at a time permits exact CRC/size local headers. No
        // streaming data descriptors or whole-archive memory buffering.
        final file = zip.ArchiveFile.bytes(
          entry.key,
          await File(p.join(root.path, entry.key)).readAsBytes(),
        )..mode = 0x8000 | entry.value.mode;
        encoder.add(file);
      }
      encoder.endEncode();
    } finally {
      await output.close();
    }
  } else {
    await Stream<TarEntry>.fromIterable(
          entries.map(
            (entry) => TarEntry(
              TarHeader(
                name: entry.key,
                size: entry.value.size,
                mode: entry.value.mode,
              ),
              File(p.join(root.path, entry.key)).openRead(),
            ),
          ),
        )
        .transform(tarWriter)
        .transform(gzip.encoder)
        .pipe(destination.openWrite());
  }
}
