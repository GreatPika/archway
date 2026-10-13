import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/tar_input.dart';

const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

List<int> member(
  String name, {
  int mode = 0x1a4,
  TypeFlag type = TypeFlag.reg,
}) => tarConverter.convert(
  TarEntry.data(TarHeader(name: name, mode: mode, typeFlag: type), [
    97,
    98,
    99,
  ]),
);

void main() {
  late Directory root;
  late Directory snapshots;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('tar-extraction-test-')
          .resolveSymbolicLinksSync(),
    );
    snapshots = Directory(p.join(root.path, 'snapshots'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('extracted files are exclusively created, never overwritten', () async {
    final source = File(p.join(root.path, 'exclusive.tar'))
      ..writeAsBytesSync([...member('first').take(1024), ...member('second')]);
    await withArchiveInput(source, (input) async {
      var finished = 0, callbacks = 0;
      await expectLater(
        withTarExtraction(
          input,
          ArchiveInventory({
            for (final name in ['first', 'second'])
              name: (size: 3, mode: 0x1a4, sha256: abc),
          }),
          (_) async => callbacks++,
          setMode: (path, _) {
            expect(File(path).resolveSymbolicLinksSync(), path);
            finished++;
            if (finished == 1) {
              File(p.join(File(path).parent.path, 'second'))
                  .writeAsStringSync('keep');
            }
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(finished, 1);
      expect(callbacks, 0);
      expect(input.file.parent.listSync().map((e) => e.path), [
        input.file.path,
      ]);
    }, temporaryParent: snapshots);
    expect(snapshots.listSync(), isEmpty);
  });

  test('all metadata is accepted before any member is extracted', () async {
    final inventory = ArchiveInventory({
      'first': (size: 3, mode: 0x1a4, sha256: abc),
      'second': (size: 3, mode: 0x1a4, sha256: abc),
    });
    for (final bytes in [
      member('first'), // Missing member.
      for (final name in [
        'first',
        '../outside',
        '/absolute',
        'SECOND',
        'first/a',
      ])
        [...member('first').take(1024), ...member(name)],
      [
        ...member('first').take(1024),
        ...member('second', type: TypeFlag.symlink),
      ],
    ]) {
      final source = File(p.join(root.path, 'metadata.tar'))
        ..writeAsBytesSync(bytes);
      await withArchiveInput(source, (input) async {
        var finishedFiles = 0, callbacks = 0;
        await expectLater(
          withTarExtraction(
            input,
            inventory,
            (_) async => callbacks++,
            setMode: (_, _) => finishedFiles++,
          ),
          throwsFormatException,
        );
        expect(finishedFiles, 0);
        expect(callbacks, 0);
        expect(input.file.parent.listSync().map((e) => e.path), [
          input.file.path,
        ]);
      }, temporaryParent: snapshots);
      expect(snapshots.listSync(), isEmpty);
    }
  });

  test(
    'later corrupt contents discard earlier verified extracted files',
    () async {
      final bytes = [...member('first').take(1024), ...member('second')]
        ..[1536] = 100;
      final source = File(p.join(root.path, 'content.tar'))
        ..writeAsBytesSync(bytes);
      await withArchiveInput(source, (input) async {
        late File first;
        var exposed = false;
        await expectLater(
          withTarExtraction(
            input,
            ArchiveInventory({
              for (final name in ['first', 'second'])
                name: (size: 3, mode: 0x1a4, sha256: abc),
            }),
            (_) async => exposed = true,
            setMode: (path, _) {
              first = File(path);
              expect(first.readAsBytesSync(), [97, 98, 99]);
            },
          ),
          throwsFormatException,
        );
        expect(exposed, isFalse);
        expect(first.parent.existsSync(), isFalse);
        expect(input.file.parent.listSync().map((e) => e.path), [
          input.file.path,
        ]);
      }, temporaryParent: snapshots);
    },
  );

  test('callback failure also removes the complete private tree', () async {
    final source = File(p.join(root.path, 'callback.tar'))
      ..writeAsBytesSync(member('a'));
    late Directory extracted;
    final error = StateError('callback failed');
    await expectLater(
      withArchiveInput(
        source,
        (input) => withTarExtraction(
          input,
          ArchiveInventory({'a': (size: 3, mode: 0x1a4, sha256: abc)}),
          (directory) async {
            extracted = directory;
            expect(File(p.join(directory.path, 'a')).readAsBytesSync(), [
              97,
              98,
              99,
            ]);
            throw error;
          },
        ),
        temporaryParent: snapshots,
      ),
      throwsA(same(error)),
    );
    expect(extracted.existsSync(), isFalse);
    expect(snapshots.listSync(), isEmpty);
  });

  test('concurrent private extractions have independent lifetimes', () async {
    final source = File(p.join(root.path, 'concurrent.tar'))
      ..writeAsBytesSync(member('a'));
    final inventory = ArchiveInventory({
      'a': (size: 3, mode: 0x1a4, sha256: abc),
    });
    final entered = Completer<void>();
    final directories = <String>{};
    await withArchiveInput(source, (input) async {
      await Future.wait([
        for (var i = 0; i < 2; i++)
          withTarExtraction(input, inventory, (directory) async {
            directories.add(directory.path);
            if (directories.length == 2) entered.complete();
            await entered.future;
            expect(File(p.join(directory.path, 'a')).readAsBytesSync(), [
              97,
              98,
              99,
            ]);
          }),
      ]);
      expect(directories, hasLength(2));
      expect(
        directories.every((path) => !Directory(path).existsSync()),
        isTrue,
      );
      expect(input.file.parent.listSync().map((e) => e.path), [
        input.file.path,
      ]);
    }, temporaryParent: snapshots);
  });

  test('mode-setting failure removes staging before callback exposure', () async {
    final source = File(p.join(root.path, 'failure.tar'))
      ..writeAsBytesSync(
        tarConverter.convert(
          TarEntry.data(TarHeader(name: 'payload', mode: 0x1ed), [97, 98, 99]),
        ),
      );
    late File written;
    var exposed = false;
    await withArchiveInput(source, (input) async {
      await expectLater(
        withTarExtraction(
          input,
          ArchiveInventory({'payload': (size: 3, mode: 0x1ed, sha256: abc)}),
          (_) async => exposed = true,
          setMode: (path, mode) {
            written = File(path);
            expect(written.readAsBytesSync(), [97, 98, 99]);
            if (Platform.isWindows) {
              // Exercise the same cleanup using a native non-directory failure.
              File(p.join(path, 'child')).openSync();
            } else {
              posix.chmod(p.join(path, 'child'), mode.toRadixString(8));
            }
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(exposed, isFalse);
      expect(written.parent.existsSync(), isFalse);
      expect(input.file.parent.listSync().map((e) => e.path), [
        input.file.path,
      ]);
    }, temporaryParent: snapshots);
    expect(snapshots.listSync(), isEmpty);
  });

  test('native Unix permissions match all accepted producer modes', () async {
    for (final mode in [0x1a4, 0x1ed, 0x1b6, 0x1ff]) {
      final source = File(p.join(root.path, 'mode.tar'))
        ..writeAsBytesSync(
          tarConverter.convert(
            TarEntry.data(TarHeader(name: 'payload', mode: mode), [97, 98, 99]),
          ),
        );
      await withArchiveInput(source, (input) async {
        await withTarExtraction(
          input,
          ArchiveInventory({'payload': (size: 3, mode: mode, sha256: abc)}),
          (directory) async {
            final file = File(p.join(directory.path, 'payload'));
            expect(file.readAsBytesSync(), [97, 98, 99]);
            // Windows retains mode provenance; it does not expose Unix chmod.
            if (!Platform.isWindows) expect(file.statSync().mode & 0xfff, mode);
          },
        );
      }, temporaryParent: snapshots);
      expect(snapshots.listSync(), isEmpty);
    }
  });

  test('verified bytes are callback-private and removed afterward', () async {
    final name = 'nested/${'café' * 26}/payload';
    final source = File(p.join(root.path, 'input.tar'))
      ..writeAsBytesSync(
        tarConverter.convert(
          TarEntry.data(TarHeader(name: name, mode: 0x1a4), [97, 98, 99]),
        ),
      );
    final inventory = ArchiveInventory({
      name: (size: 3, mode: 0x1a4, sha256: abc),
    });
    late Directory extracted;
    await withArchiveInput(source, (input) async {
      final result = await withTarExtraction(input, inventory, (
        directory,
      ) async {
        extracted = directory;
        expect(
          File(p.joinAll([directory.path, ...name.split('/')]))
              .readAsBytesSync(),
          [97, 98, 99],
        );
        expect(directory.parent.path, input.file.parent.path);
        if (!Platform.isWindows)
          expect(directory.statSync().mode & 0xfff, 0x1c0);
        return 'verified';
      });
      expect(result, 'verified');
      expect(extracted.existsSync(), isFalse);
      expect(input.file.existsSync(), isTrue);
    }, temporaryParent: snapshots);
    expect(snapshots.listSync(), isEmpty);
    expect(source.existsSync(), isTrue);
  });
}
