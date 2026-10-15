// Independently bind final release inputs to the complete native producer policy.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/generate_descriptor.dart';
import '../release/installation_identity.dart';
import '../release/native_payload.dart';
import 'release_execution_receipts.dart';
import 'release_receipt_values.dart';

// The descriptor snapshot is owned only during withNativeReleaseInput's callback.
final class NativeReleaseInput {
  NativeReleaseInput({
    required this.source,
    required this.version,
    required this.descriptor,
    required this.descriptorFile,
    required this.descriptorSha256,
    required this.assets,
    required this.sums,
    required this.packagingBytes,
  });
  final Map<String, Object?> source, descriptor;
  final String version, descriptorSha256;
  final File descriptorFile;
  final Map<String, File> assets;
  final Map<String, String> sums;
  final List<int> packagingBytes;
}

Future<T> withNativeReleaseInput<T>({
  required Directory source,
  required Directory native,
  required File descriptor,
  required String expectedCommit,
  required Future<T> Function(NativeReleaseInput) inspect,
}) async {
  final identity = await sourceIdentity(source);
  requireReceipt(
    identity['commit'] == expectedCommit,
    'Native finalization source differs',
  );
  return withArchiveInput(descriptor, (snapshot) async {
    final temporary = await Directory.systemTemp.createTemp(
      'archway-final-descriptor-',
    );
    try {
      final generated = Directory(p.join(temporary.path, 'generated'));
      final packagingFile = File(p.join(native.path, 'native-packaging.json'));
      final packagingBytes = readOrdinaryBytes(
        packagingFile,
        limit: maxArchiveJsonBytes,
      );
      // This shared owner authenticates every native archive and complete payload.
      await generateDescriptor(
        source: source,
        native: native,
        output: generated,
        expectedCommit: expectedCommit,
      );
      requireReceipt(
        sha256.convert(
              readOrdinaryBytes(packagingFile, limit: maxArchiveJsonBytes),
            ) ==
            sha256.convert(packagingBytes),
        'Native producer receipt changed during verification',
      );
      final generatedFile = File(p.join(generated.path, 'acquisition.json'));
      final bytes = readOrdinaryBytes(
        generatedFile,
        limit: maxArchiveJsonBytes,
      );
      requireReceipt(
        sha256.convert(bytes).toString() == snapshot.sha256 &&
            bytes.length == snapshot.size,
        'Acquisition descriptor differs from native producer',
      );
      final value = receiptObject(readRecord(generatedFile));
      requireReceipt(
        exactReceipt(value['source'], identity),
        'Native descriptor source changed',
      );
      final version = value['version'] as String;
      final targets = receiptObject(value['targets']);
      final assets = <String, File>{'acquisition.json': snapshot.file};
      final sums = <String, String>{'acquisition.json': snapshot.sha256};
      for (final target in nativeTargets.keys) {
        final name =
            'archway-$version-$target${target == 'windows-x64' ? '.zip' : '.tar.gz'}';
        assets[name] = File(p.join(native.path, name));
        sums[name] = receiptObject(targets[target])['sha256'] as String;
      }
      final entries = native.listSync(followLinks: false);
      final expected = {
        'native-packaging.json',
        'SHA256SUMS',
        'evidence',
        ...assets.keys.where((name) => name != 'acquisition.json'),
      };
      requireReceipt(
        entries.length == expected.length &&
            entries.every(
              (entry) =>
                  expected.contains(p.basename(entry.path)) &&
                  (p.basename(entry.path) == 'evidence'
                      ? entry is Directory
                      : entry is File),
            ),
        'Unexpected native producer directory inventory',
      );
      final names =
          sums.keys.where((name) => name != 'acquisition.json').toList()
            ..sort();
      final expectedSums = names.map((name) => '${sums[name]}  $name\n').join();
      requireReceipt(
        utf8.decode(
              readOrdinaryBytes(
                File(p.join(native.path, 'SHA256SUMS')),
                limit: maxArchiveJsonBytes,
              ),
            ) ==
            expectedSums,
        'Native producer checksums differ from verified archives',
      );
      final result = await inspect(
        NativeReleaseInput(
          source: Map.unmodifiable(identity),
          version: version,
          descriptor: Map.unmodifiable(value),
          descriptorFile: snapshot.file,
          descriptorSha256: snapshot.sha256,
          assets: Map.unmodifiable(assets),
          sums: Map.unmodifiable(sums),
          packagingBytes: List.unmodifiable(packagingBytes),
        ),
      );
      requireReceipt(
        exactReceipt(await sourceIdentity(source), identity),
        'Source changed during native finalization',
      );
      return result;
    } finally {
      await temporary.delete(recursive: true);
    }
  }, maxBytes: maxArchiveJsonBytes);
}
