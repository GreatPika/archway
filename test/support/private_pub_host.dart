// Private registry snapshot only: dependency archives are repacked trusted cache
// trees, not official pub.dev archive bytes or public installation acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:tar/tar.dart';
import 'package:yaml/yaml.dart';

import '../../tool/release/archive_input.dart';
import '../../tool/release/gzip_input.dart';
import '../../tool/release/tar_input.dart';

final class PrivatePubHost {
  PrivatePubHost._(this._server, this._responses)
    : url = Uri.parse('http://127.0.0.1:${_server.port}/') {
    _done = _serve().then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _failure = (error, stack);
      },
    );
  }

  final HttpServer _server;
  final Map<String, ({List<int> bytes, ContentType type})> _responses;
  final Uri url;
  final List<String> requests = [];
  late final Future<void> _done;
  (Object, StackTrace)? _failure;
  Future<void>? _closing;

  /// Uses the exact SDK upload and the lock-selected runtime dependency closure.
  /// [preparedPubCache] is read-only; activation must use a separate empty cache.
  static Future<PrivatePubHost> start(
    File archwayUpload,
    Directory preparedPubCache, {
    required String expectedVersion,
    File? dependencyLockfile,
  }) async {
    _physical(preparedPubCache, FileSystemEntityType.directory);
    final lock =
        _yaml(
              (dependencyLockfile ?? File('pubspec.lock')).readAsStringSync(),
            )['packages']
            as Map;
    final packages = <String, ({Map pubspec, List<int> bytes})>{};
    packages['archway'] = await withArchiveInput(archwayUpload, (input) async {
      final pubspec = await _uploadPubspec(input);
      if (pubspec['name'] != 'archway' || pubspec['version'] != expectedVersion) {
        throw FormatException('Expected archway $expectedVersion SDK upload');
      }
      return (pubspec: pubspec, bytes: await input.file.readAsBytes());
    }, maxBytes: 32 * 1024 * 1024);
    final pending = ['archway'];
    while (pending.isNotEmpty) {
      final spec = packages[pending.removeLast()]!.pubspec;
      for (final dependency in (spec['dependencies'] as Map? ?? {}).entries) {
        final name = dependency.key as String;
        final pin = lock[name];
        if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name) ||
            dependency.value is! String ||
            pin is! Map ||
            pin['source'] != 'hosted') {
          throw FormatException('Expected locked hosted dependency: $name');
        }
        final version = Version.parse(pin['version'] as String);
        if (!VersionConstraint.parse(dependency.value as String)
            .allows(version)) {
          throw FormatException('Locked dependency violates constraint: $name');
        }
        if (packages.containsKey(name)) continue;
        final root = Directory(
          p.join(preparedPubCache.path, 'hosted', 'pub.dev', '$name-$version'),
        );
        _physical(root, FileSystemEntityType.directory);
        final packed = _pack(root);
        if (packed.pubspec['name'] != name ||
            packed.pubspec['version'] != version.toString()) {
          throw FormatException('Prepared package identity differs: $name');
        }
        packages[name] = packed;
        pending.add(name);
      }
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final responses = <String, ({List<int> bytes, ContentType type})>{};
      void json(String path, Object value) => responses[path] = (
        bytes: utf8.encode(jsonEncode(value)),
        type: ContentType.json,
      );
      for (final entry in packages.entries) {
        final name = entry.key, package = entry.value;
        final version = package.pubspec['version'];
        final archivePath = '/archives/$name-$version.tar.gz';
        final metadata = {
          'version': version,
          'pubspec': package.pubspec,
          'archive_url': base.resolve(archivePath).toString(),
          'archive_sha256': sha256.convert(package.bytes).toString(),
        };
        json('/api/packages/$name', {
          'name': name,
          'latest': metadata,
          'versions': [metadata],
        });
        json('/api/packages/$name/advisories', {'advisories': []});
        responses[archivePath] = (
          bytes: package.bytes,
          type: ContentType('application', 'octet-stream'),
        );
      }
      return PrivatePubHost._(server, responses);
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      requests.add(request.uri.toString());
      final response = request.method == 'GET'
          ? _responses[request.uri.toString()]
          : null;
      if (response == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentType = response.type;
        request.response.contentLength = response.bytes.length;
        request.response.add(response.bytes);
      }
      await request.response.close();
    }
  }

  /// Idempotent, including when stopped before offline execution assertions.
  Future<void> close() => _closing ??= () async {
    await _server.close(force: true);
    await _done;
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }();
}

Map _yaml(String text) => jsonDecode(jsonEncode(loadYaml(text))) as Map;

void _physical(FileSystemEntity entity, FileSystemEntityType type) {
  if (FileSystemEntity.typeSync(entity.path, followLinks: false) != type ||
      entity.resolveSymbolicLinksSync() != entity.absolute.path) {
    throw FormatException('Expected physical fixture input: ${entity.path}');
  }
}

({Map pubspec, List<int> bytes}) _pack(Directory root) {
  final archive = Archive();
  final identities = <String, ArchiveFileIdentity>{};
  Map? pubspec;
  var total = 0;
  final entries = root.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  if (entries.length > maxArchiveEntries) {
    throw const FormatException('Prepared package exceeds entry bound');
  }
  for (final entity in entries) {
    if (entity is Directory) {
      _physical(entity, FileSystemEntityType.directory);
      continue;
    }
    _physical(entity, FileSystemEntityType.file);
    final file = File(entity.path);
    final size = file.lengthSync();
    total += size;
    if (size > maxArchiveFileBytes || total > 32 * 1024 * 1024) {
      throw const FormatException('Prepared package exceeds byte bound');
    }
    final name = p
        .relative(entity.path, from: root.path)
        .split(p.separator)
        .join('/');
    final bytes = file.readAsBytesSync();
    identities[name] = (
      size: bytes.length,
      mode: 0x1a4,
      sha256: sha256.convert(bytes).toString(),
    );
    archive.add(ArchiveFile.bytes(name, bytes)..lastModTime = 0);
    if (name == 'pubspec.yaml') pubspec = _yaml(utf8.decode(bytes));
  }
  ArchiveInventory(identities);
  if (pubspec == null) throw const FormatException('Missing prepared pubspec');
  return (
    pubspec: pubspec,
    bytes: gzip.encode(TarEncoder().encodeBytes(archive)),
  );
}

Future<Map> _uploadPubspec(ArchiveInput input) => withGzipSnapshot(input, (
  tar,
) async {
  final reader = TarReader(tar.openRead(), maxSpecialFileSize: 1024 * 1024);
  final identities = <String, ArchiveFileIdentity>{};
  Map? pubspec;
  try {
    while (await reader.moveNext()) {
      final header = reader.current.header;
      if (header.typeFlag == TypeFlag.dir) continue;
      if (header.typeFlag != TypeFlag.reg ||
          identities.containsKey(header.name) ||
          identities.length >= maxArchiveEntries ||
          header.size > maxArchiveFileBytes) {
        throw const FormatException('Invalid SDK upload member');
      }
      final bytes = await reader.current.contents.fold(
        <int>[],
        (a, b) => a..addAll(b),
      );
      identities[header.name] = (
        size: bytes.length,
        mode: header.mode,
        sha256: sha256.convert(bytes).toString(),
      );
      if (header.name == 'pubspec.yaml') pubspec = _yaml(utf8.decode(bytes));
    }
  } finally {
    await reader.cancel();
  }
  await withArchiveInput(
    tar,
    (snapshot) => verifyTarInput(
      snapshot,
      ArchiveInventory(identities),
      dialect: TarDialect.pubUpload,
    ),
  );
  if (pubspec == null)
    throw const FormatException('Missing SDK upload pubspec');
  return pubspec;
}, maxExpandedBytes: 32 * 1024 * 1024);
