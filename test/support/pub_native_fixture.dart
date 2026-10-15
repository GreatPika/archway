// Synthetic native inputs for CI route controls; never real core acceptance.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pub_stage_fixture.dart';

String get pubFixtureTarget => switch (Abi.current()) {
  Abi.linuxX64 => 'linux-x64',
  Abi.macosArm64 => 'macos-arm64',
  Abi.windowsX64 => 'windows-x64',
  _ => throw UnsupportedError('Unsupported test host'),
};

File preparePubNativeFixture(
  PubStageFixture fixture, {
  File? executable,
  String? target,
}) {
  target ??= pubFixtureTarget;
  final name = 'bin/$target/archway${target == 'windows-x64' ? '.exe' : ''}';
  final bytes =
      executable?.readAsBytesSync() ??
      utf8.encode('inert bytes, never executed');
  final manifest = utf8.encode(
    jsonEncode({
      'version': '0.2.0',
      'source': fixture.identity,
      'target': target,
      'files': {
        name: {
          'size': bytes.length,
          'mode': 493,
          'sha256': sha256.convert(bytes).toString(),
        },
      },
    }),
  );
  // ZIP carries the regular-file type in its Unix external attributes; tar's
  // encoder supplies its own type field and keeps only the permission bits.
  final type = target == 'windows-x64' ? 0x8000 : 0;
  final archive = Archive()
    ..add(ArchiveFile.bytes(name, bytes)..mode = type | 493)
    ..add(ArchiveFile.bytes('manifest.json', manifest)..mode = type | 420);
  final packed = target == 'windows-x64'
      ? ZipEncoder().encodeBytes(archive)
      : gzip.encode(TarEncoder().encodeBytes(archive));
  final native = File(p.join(fixture.root.path, 'native.payload'))
    ..writeAsBytesSync(packed);
  final descriptor = jsonDecode(fixture.descriptor.readAsStringSync()) as Map;
  (descriptor['targets'] as Map)[target] = {
    ...((descriptor['targets'] as Map)[target] as Map),
    'size': packed.length,
    'sha256': sha256.convert(packed).toString(),
    'manifest_sha256': sha256.convert(manifest).toString(),
  };
  fixture.descriptor.writeAsStringSync(jsonEncode(descriptor));
  return native;
}
