import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/pub/native_cache.dart';
import 'support/native_release_fixture.dart';

void main() {
  late NativeReleaseFixture fixture;
  late Map<String, Object?> descriptor;
  late Directory native, cache;
  final requests = <Uri>[];
  setUp(() async {
    fixture = await prepareNativeReleaseFixture();
    final result = await buildNativeFixture(fixture, 'native');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    native = Directory(p.join(fixture.root.path, 'native'));
    cache = Directory(p.join(fixture.root.path, 'private cache café'));
    final receipt = jsonDecode(
      File(p.join(native.path, 'native-packaging.json')).readAsStringSync(),
    ) as Map;
    descriptor = {
      'schema_version': 1,
      'version': '1.2.3',
      'source': fixture.identity,
      'targets': {
        for (final target in ['linux-x64', 'macos-arm64', 'windows-x64'])
          target: {
            'url':
                'https://example.invalid/${receipt['native_bundles'][target]['filename']}',
            for (final key in ['size', 'sha256', 'manifest_sha256'])
              key: receipt['native_bundles'][target][key],
          },
      },
    };
    requests.clear();
  });
  tearDown(() => fixture.root.deleteSync(recursive: true));
  Future<void> fetch(Uri uri, File output, int expected) async {
    requests.add(uri);
    final source = File(p.join(native.path, uri.pathSegments.last));
    expect(source.lengthSync(), expected);
    source.copySync(output.path);
  }

  test(
    'cold acquisition selects one target and warm launch requires no transport',
    () async {
      final binary = await acquirePubNative(
        descriptor,
        'linux-x64',
        cache,
        download: fetch,
      );
      expect(binary.readAsStringSync(), 'synthetic binary linux-x64');
      expect(requests.map((e) => e.path), ['/archway-1.2.3-linux-x64.tar.gz']);
      final second = await acquirePubNative(
        descriptor,
        'linux-x64',
        cache,
        download: (_, _, _) =>
            throw StateError('Warm launch requested transport'),
      );
      expect(second.path, binary.path);
      final installed = binary.parent.parent.parent;
      expect(
        File(p.join(installed.path, 'manifest.json')).existsSync(),
        isTrue,
      );
      expect(
        cache
            .listSync(recursive: true)
            .where((e) => p.basename(e.path).startsWith('.archway-')),
        isEmpty,
      );
    },
  );
  test(
    'ZIP target uses verified publication and selects its executable',
    () async {
      final binary = await acquirePubNative(
        descriptor,
        'windows-x64',
        cache,
        download: fetch,
      );
      expect(binary.readAsStringSync(), 'synthetic binary windows-x64');
      expect(requests.map((e) => e.path), ['/archway-1.2.3-windows-x64.zip']);
      expect(p.basename(binary.path), 'archway.exe');
    },
  );
  test(
    'corrupt executable and manifest fail closed without repair or removal',
    () async {
      final binary = await acquirePubNative(
        descriptor,
        'linux-x64',
        cache,
        download: fetch,
      );
      final manifest = File(
        p.join(binary.parent.parent.parent.path, 'manifest.json'),
      );
      final original = binary.readAsBytesSync();
      final changed = List<int>.of(original)..[0] ^= 1;
      binary.writeAsBytesSync(changed);
      await expectLater(
        acquirePubNative(descriptor, 'linux-x64', cache, download: fetch),
        throwsFormatException,
      );
      expect(binary.readAsBytesSync(), changed);
      expect(requests, hasLength(1));
      binary.writeAsBytesSync(original);
      final manifestBytes = [...manifest.readAsBytesSync(), 10];
      manifest.writeAsBytesSync(manifestBytes);
      await expectLater(
        acquirePubNative(descriptor, 'linux-x64', cache, download: fetch),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('manifest differs'),
          ),
        ),
      );
      expect(manifest.readAsBytesSync(), manifestBytes);
      expect(requests, hasLength(1));
    },
  );
  test(
    'warm identity leaves unrelated native asset checks to the core',
    () async {
      final binary = await acquirePubNative(
        descriptor,
        'linux-x64',
        cache,
        download: fetch,
      );
      final helper = File(
        p.join(
          binary.parent.parent.parent.path,
          'assets/typescript/helper.cjs',
        ),
      );
      helper.writeAsStringSync('changed helper');
      expect(
        (await acquirePubNative(
          descriptor,
          'linux-x64',
          cache,
          download: fetch,
        )).path,
        binary.path,
      );
      expect(requests, hasLength(1));
      expect(helper.readAsStringSync(), 'changed helper');
    },
  );
  test(
    'failed download and altered archive cannot become usable cache entries',
    () async {
      final selected = (descriptor['targets'] as Map)['linux-x64'] as Map;
      final destination = Directory(
        p.join(cache.path, '1.2.3', 'linux-x64', selected['sha256'] as String),
      );
      await expectLater(
        acquirePubNative(
          descriptor,
          'linux-x64',
          cache,
          download: (_, output, _) async {
            output.writeAsBytesSync([1, 2]);
            throw const FileSystemException('interrupted fixture');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(destination.existsSync(), isFalse);
      await expectLater(
        acquirePubNative(
          descriptor,
          'linux-x64',
          cache,
          download: (url, output, size) async {
            await fetch(url, output, size);
            final bytes = output.readAsBytesSync()..[10] ^= 1;
            output.writeAsBytesSync(bytes);
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('pinned identity'),
          ),
        ),
      );
      expect(destination.existsSync(), isFalse);
      expect(
        cache
            .listSync(recursive: true)
            .where((e) => p.basename(e.path).startsWith('.archway-')),
        isEmpty,
      );
    },
  );
  test(
    'concurrent valid fills converge and a corrupt winner is never admitted',
    () async {
      final results = await Future.wait([
        acquirePubNative(descriptor, 'linux-x64', cache, download: fetch),
        acquirePubNative(descriptor, 'linux-x64', cache, download: fetch),
      ]);
      expect(results[0].path, results[1].path);
      expect(results[0].readAsStringSync(), 'synthetic binary linux-x64');
      expect(
        cache
            .listSync(recursive: true)
            .where((e) => p.basename(e.path).startsWith('.archway-')),
        isEmpty,
      );
      final other = Directory(p.join(fixture.root.path, 'other cache'));
      final selected = (descriptor['targets'] as Map)['linux-x64'] as Map;
      final winner = Directory(
        p.join(other.path, '1.2.3', 'linux-x64', selected['sha256'] as String),
      );
      await expectLater(
        acquirePubNative(
          descriptor,
          'linux-x64',
          other,
          download: (url, output, size) async {
            await fetch(url, output, size);
            winner.createSync();
            File(p.join(winner.path, 'manifest.json')).writeAsStringSync('{}');
          },
        ),
        throwsFormatException,
      );
      expect(
        File(p.join(winner.path, 'manifest.json')).readAsStringSync(),
        '{}',
      );
      expect(winner.listSync().length, 1);
    },
  );
  test(
    'unsupported targets and aliased cache parents fail before transport',
    () async {
      await expectLater(
        acquirePubNative(descriptor, 'linux-arm64', cache, download: fetch),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('Unsupported native target'),
          ),
        ),
      );
      expect(cache.existsSync(), isFalse);
      final outside = Directory(p.join(fixture.root.path, 'outside'))
        ..createSync();
      Link(cache.path).createSync(outside.path);
      await expectLater(
        acquirePubNative(descriptor, 'linux-x64', cache, download: fetch),
        throwsFormatException,
      );
      expect(outside.listSync(), isEmpty);
      expect(requests, isEmpty);
    },
  );
}
