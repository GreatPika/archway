import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import 'support/node_package_fixtures.dart';

void main() {
  late Directory temporary;
  setUp(
    () => temporary = Directory.systemTemp.createTempSync(
      'archway-node-fixture-',
    ),
  );
  tearDown(() => temporary.deleteSync(recursive: true));
  Future<File> archive(List<TarEntry> entries) async {
    final file = File(p.join(temporary.path, 'fixture.tar.gz'));
    await Stream.fromIterable(entries)
        .transform(tarWriter)
        .transform(gzip.encoder)
        .pipe(file.openWrite());
    return file;
  }

  TarEntry member(
    String name,
    TypeFlag type, {
    String? target,
    List<int> bytes = const [],
  }) => TarEntry.data(
    TarHeader(name: name, typeFlag: type, linkName: target, mode: 0x1ed),
    bytes,
  );

  test(
    'Windows native fixture paths keep drive, UNC and extended spelling',
    () {
      for (final paths in [
        [r'C:\package café\index.d.ts', r'\\?\C:\package café\index.d.ts'],
        [
          r'\\server\share\package\index.d.ts',
          r'\\?\UNC\server\share\package\index.d.ts',
        ],
        [r'\\?\C:\deep\index.d.ts', r'\\?\C:\deep\index.d.ts'],
        [
          r'\\?\UNC\server\share\index.d.ts',
          r'\\?\UNC\server\share\index.d.ts',
        ],
      ]) {
        expect(nodeFixtureWindowsNativePath(paths[0]), paths[1]);
      }
    },
  );

  for (final deep in [false, true]) {
    test(
      deep
          ? 'deep relative destination preserves directory links and real hardlinks'
          : 'relative directory links and real hardlinks survive',
      () async {
        final input = await archive([
          member('store', TypeFlag.dir),
          member('store/package', TypeFlag.dir),
          member('node_modules', TypeFlag.dir),
          member('store/package/index.d.ts', TypeFlag.reg, bytes: [120]),
          member(
            'store/package/copy.d.ts',
            TypeFlag.link,
            target: 'store/package/index.d.ts',
          ),
          member(
            'node_modules/package',
            TypeFlag.symlink,
            target: '../store/package',
          ),
        ]);
        final destination = p.joinAll([
          temporary.path,
          if (deep) ...List.filled(3, 'package café'.padRight(100, 'x')),
          'output',
        ]);
        // Exercise relative caller paths too: only the FFI arguments become
        // absolute/extended. Archive names and stored symlink targets must not.
        final output = Directory(deep ? p.relative(destination) : destination);
        if (deep) {
          for (final name in [
            'store/package/index.d.ts',
            'store/package/copy.d.ts',
            'node_modules/package',
          ]) {
            expect(p.join(destination, name).length, greaterThan(260));
          }
        }
        await extractNodeFixture(input, output);
        final link = Link(p.join(output.path, 'node_modules/package'));
        expect(
          link.targetSync(),
          ['..', 'store', 'package'].join(Platform.pathSeparator),
        );
        expect(FileSystemEntity.isLinkSync(link.path), isTrue);
        expect(File(p.join(link.path, 'index.d.ts')).readAsBytesSync(), [120]);
        expect(
          FileSystemEntity.identicalSync(
            p.join(output.path, 'store/package/index.d.ts'),
            p.join(output.path, 'store/package/copy.d.ts'),
          ),
          isTrue,
        );
      },
    );
  }

  for (final target in ['../outside', '/outside', r'C:\outside']) {
    test('escaping symbolic link $target rejected before extraction', () async {
      final input = await archive([
        member('alias', TypeFlag.symlink, target: target),
      ]);
      final output = Directory(p.join(temporary.path, 'output'));
      await expectLater(
        extractNodeFixture(input, output),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);
    });
  }
  test('archive member cannot traverse an archived alias', () async {
    final input = await archive([
      member('store', TypeFlag.dir),
      member('alias', TypeFlag.symlink, target: 'store'),
      member('alias/file', TypeFlag.reg, bytes: [120]),
    ]);
    final output = Directory(p.join(temporary.path, 'output'));
    await expectLater(extractNodeFixture(input, output), throwsFormatException);
    expect(output.existsSync(), isFalse);
  });
  test('existing destination alias is never followed', () async {
    final outside = Directory(p.join(temporary.path, 'outside'))..createSync();
    final output = Directory(p.join(temporary.path, 'output'))..createSync();
    Link(p.join(output.path, 'store')).createSync(outside.path);
    final input = await archive([
      member('store/file', TypeFlag.reg, bytes: [120]),
    ]);
    await expectLater(extractNodeFixture(input, output), throwsFormatException);
    expect(outside.listSync(), isEmpty);
  });
  test(
    'committed archives preserve files, links, hardlinks and file modes',
    () async {
      final output = Directory(p.join(temporary.path, 'output'));
      var links = 0, hardlinks = 0;
      for (final name in [
        'prepared.tar.gz',
        'addon.tar.gz',
        'npm-override.tar.gz',
      ]) {
        final input = File(p.join('test/fixtures/node-packages', name));
        await extractNodeFixture(input, output);
        final reader = TarReader(input.openRead().transform(gzip.decoder));
        try {
          while (await reader.moveNext()) {
            final header = reader.current.header;
            final path = p.joinAll([output.path, ...header.name.split('/')]);
            if (header.typeFlag == TypeFlag.symlink) {
              links++;
              expect(
                Link(path).targetSync(),
                header.linkName!.replaceAll('/', Platform.pathSeparator),
              );
              expect(Directory(path).existsSync(), isTrue);
            } else if (header.typeFlag == TypeFlag.link) {
              hardlinks++;
              expect(
                FileSystemEntity.identicalSync(
                  path,
                  p.joinAll([output.path, ...header.linkName!.split('/')]),
                ),
                isTrue,
              );
            } else if (header.typeFlag == TypeFlag.reg) {
              final bytes = await reader.current.contents.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              );
              expect(File(path).readAsBytesSync(), bytes);
              if (!Platform.isWindows)
                expect(File(path).statSync().mode & 0x1ff, header.mode & 0x1ff);
            }
          }
        } finally {
          await reader.cancel();
        }
      }
      expect(links, 38);
      expect(hardlinks, greaterThan(0));
      expect(
        File(
          p.join(
            output.path,
            'pnpm-registry/node_modules/ansi-regex/package.json',
          ),
        ).readAsStringSync(),
        contains('6.1.0'),
      );
    },
  );
}
