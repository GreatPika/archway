import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import '../zip_input_test.dart' show zip, central, set32;

Future<({File archive, Map<String, Object> pin, Map<String, Object> identity})>
npmNativeFixture(
  Directory root,
  String format, {
  List<(String, List<int>)> extra = const [],
  List<int> payload = const [97, 98, 99],
  int executableMode = 0x1a4,
  Map<String, Object>? sourceIdentity,
  String? nativeTarget,
  void Function(Map<String, Object>)? changeManifest,
  void Function(List<int>)? changeArchive,
  TypeFlag extraType = TypeFlag.reg,
  int zipMode = 0x81a4,
  List<(String, List<int>)> Function(List<(String, List<int>)>)? changeMembers,
}) async {
  final payloadHash = sha256.convert(payload).toString();
  final source =
      sourceIdentity ??
      {
        'commit': 'a' * 40,
        'tree': 'b' * 40,
        'lockfile_sha256': {
          'pubspec.lock': 'c' * 64,
          'assets/typescript/package-lock.json': 'd' * 64,
        },
      };
  final target =
      nativeTarget ?? (format == 'zip' ? 'windows-x64' : 'linux-x64');
  final executable = 'bin/$target/archway${format == 'zip' ? '.exe' : ''}';
  final identity = <String, Object>{
    'version': '1.2.3',
    'source': source,
    'target': target,
  };
  final value = <String, Object>{
    ...identity,
    'files': {
      executable: {
        'size': payload.length,
        'mode': executableMode,
        'sha256': payloadHash,
      },
      for (final (name, bytes) in extra)
        name: {
          'size': bytes.length,
          'mode': 0x1a4,
          'sha256': sha256.convert(bytes).toString(),
        },
    },
  };
  changeManifest?.call(value);
  final manifest = utf8.encode(jsonEncode(value));
  var members = [(executable, payload), ...extra, ('manifest.json', manifest)];
  members = changeMembers?.call(members) ?? members;
  final bytes = format == 'zip'
      ? zip(members, mode: zipMode)
      : gzip.encode(
          await Stream<TarEntry>.fromIterable(
            members.map(
              (e) => TarEntry.data(
                TarHeader(
                  name: e.$1,
                  mode: e.$1 == executable ? executableMode : 0x1a4,
                  typeFlag: e.$1 == 'odd' ? extraType : TypeFlag.reg,
                ),
                e.$2,
              ),
            ),
          ).transform(tarWriter).fold<List<int>>([], (a, b) => a..addAll(b)),
        );
  if (format == 'zip')
    set32(
      bytes as Uint8List,
      central(bytes) + 38,
      (0x8000 | executableMode) << 16,
    );
  changeArchive?.call(bytes);
  final archive = File(p.join(root.path, 'native.$format'))
    ..writeAsBytesSync(bytes);
  return (
    archive: archive,
    pin: {
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'manifest_sha256': sha256.convert(manifest).toString(),
    },
    identity: identity,
  );
}
