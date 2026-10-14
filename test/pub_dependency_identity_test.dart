import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/pub/dependency_identity.dart';

void main() {
  test('dependency identity binds source lock, cache hash records, and physical content', () async {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('pub dependency-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final lock = File(p.join(root.path, 'resolved.lock'));
    final source = File(p.join(root.path, 'source.lock'));
    final value = {
      'packages': {
        'fixture': {
          'source': 'hosted',
          'version': '1.2.3',
          'description': {'url': 'https://pub.dev', 'sha256': 'a' * 64},
        },
      },
    };
    lock.writeAsStringSync(jsonEncode(value));
    source.writeAsStringSync(jsonEncode(value));
    final cache = Directory(p.join(root.path, 'cache'));
    final hash = File(
      p.join(cache.path, 'hosted-hashes/pub.dev/fixture-1.2.3.sha256'),
    );
    hash.parent.createSync(recursive: true);
    hash.writeAsStringSync('${'a' * 64}\n');
    final file = File(
      p.join(cache.path, 'hosted/pub.dev/fixture-1.2.3/lib/fixture.dart'),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('original bytes');
    final package = Directory(
      p.join(cache.path, 'hosted', 'pub.dev', 'fixture-1.2.3'),
    );
    final moved = package.renameSync(p.join(root.path, 'moved-package'));
    final alias = Link(package.path)..createSync(moved.path);
    await expectLater(
      pubDependencyIdentity(lock, source, cache),
      throwsFormatException,
    );
    alias.deleteSync();
    moved.renameSync(package.path);
    final before = await pubDependencyIdentity(lock, source, cache);
    file.writeAsStringSync('changed bytes!');
    final after = await pubDependencyIdentity(lock, source, cache);
    expect(
      (before['fixture'] as Map)['content_sha256'],
      isNot((after['fixture'] as Map)['content_sha256']),
    );
    hash.writeAsStringSync('${'b' * 64}\n');
    await expectLater(
      pubDependencyIdentity(lock, source, cache),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diagnostic',
          contains('Dependency cache differs'),
        ),
      ),
    );
    hash.writeAsStringSync('${'a' * 64}\n');
    value['packages']!['fixture']!['version'] = '1.2.4';
    lock.writeAsStringSync(jsonEncode(value));
    await expectLater(
      pubDependencyIdentity(lock, source, cache),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diagnostic',
          contains('Resolved dependency differs'),
        ),
      ),
    );
  });
}
