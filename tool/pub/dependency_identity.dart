// Bind SDK preparation to canonical lock pins and detect cached-byte mutation.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../ci/release_execution_receipts.dart' show readOrdinaryBytes;

Future<Map<String, Object?>> pubDependencyIdentity(
  File lock,
  File sourceLock,
  Directory cache,
) async {
  Map packages(File file) {
    final value = loadYaml(
      utf8.decode(readOrdinaryBytes(file, limit: 2 * 1024 * 1024)),
    );
    if (value is! Map || value['packages'] is! Map) {
      throw const FormatException('Invalid pub dependency lock');
    }
    return value['packages'] as Map;
  }

  final resolved = packages(lock), expected = packages(sourceLock);
  if (resolved.isEmpty)
    throw const FormatException('Missing resolved pub dependencies');
  final result = <String, Object?>{};
  for (final name in resolved.keys.cast<String>().toList()..sort()) {
    final actual = resolved[name], pinned = expected[name];
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name) ||
        actual is! Map ||
        pinned is! Map ||
        actual['source'] != 'hosted' ||
        pinned['source'] != 'hosted' ||
        actual['version'] != pinned['version'] ||
        actual['description'] is! Map ||
        pinned['description'] is! Map ||
        actual['description']['url'] != 'https://pub.dev' ||
        pinned['description']['url'] != 'https://pub.dev' ||
        actual['description']['sha256'] != pinned['description']['sha256']) {
      throw FormatException(
        'Resolved dependency differs from canonical lock: $name',
      );
    }
    final version = actual['version'] as String,
        digest = actual['description']['sha256'] as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$')
            .hasMatch(version)) {
      throw const FormatException('Invalid resolved dependency identity');
    }
    final directory = Directory(
      p.join(cache.path, 'hosted', 'pub.dev', '$name-$version'),
    );
    final hash = File(
      p.join(cache.path, 'hosted-hashes', 'pub.dev', '$name-$version.sha256'),
    );
    if (utf8.decode(readOrdinaryBytes(hash)).trim() != digest ||
        directory.resolveSymbolicLinksSync() != directory.absolute.path) {
      throw FormatException(
        'Dependency cache differs from canonical lock: $name',
      );
    }
    final inventory = <String, Object?>{};
    final entries = directory.listSync(recursive: true, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (entry is Directory) {
        if (entry.resolveSymbolicLinksSync() != entry.absolute.path) {
          throw const FormatException('Aliased dependency directory');
        }
      } else if (entry is File) {
        final bytes = readOrdinaryBytes(entry);
        inventory[p
            .relative(entry.path, from: directory.path)
            .split(p.separator)
            .join('/')] = {
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        };
      } else {
        throw const FormatException('Nonordinary dependency entry');
      }
    }
    result[name] = {
      'version': version,
      'sha256': digest,
      'content_sha256': sha256
          .convert(utf8.encode(jsonEncode(inventory)))
          .toString(),
    };
  }
  return result;
}
