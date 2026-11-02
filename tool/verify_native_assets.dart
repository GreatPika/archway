// Maintainer check only. The build hook never downloads or compiles assets.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main() => verifyNativeAssets(File.fromUri(Platform.script).parent.parent);

void verifyNativeAssets(Directory root) {
  final inventory = jsonDecode(
    File('${root.path}/native/assets.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  if (inventory['abi_version'] != 2) throw StateError('Unsupported bridge ABI');
  final sources = (inventory['source_sha256'] as Map).cast<String, String>();
  for (final entry in sources.entries) {
    final bytes = File('${root.path}/${entry.key}').readAsBytesSync();
    if (sha256.convert(bytes).toString() != entry.value) {
      throw StateError(
        'Bridge source changed; rebuild and reverify assets: ${entry.key}',
      );
    }
  }
  final assets = inventory['assets'] as List;
  const expected = {
    'native/linux-x64/libarchway_io.so',
    'native/macos-arm64/libarchway_io.dylib',
    'native/windows-x64/archway_io.dll',
  };
  final members = assets.map((asset) => asset['member']).toSet();
  if (assets.length != expected.length ||
      members.length != expected.length ||
      !expected.containsAll(members)) {
    throw StateError('Incomplete supported native asset inventory');
  }
  for (final asset in assets) {
    final bytes = File('${root.path}/${asset['member']}').readAsBytesSync();
    if (bytes.length != asset['size'] ||
        sha256.convert(bytes).toString() != asset['sha256']) {
      throw StateError(
        'Bundled bridge does not match inventory: ${asset['member']}',
      );
    }
  }
  stdout.writeln(
    '3 bundled ABI 2 assets and ${sources.length} source inputs verified.',
  );
}
