import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/installation_artifact.dart';
import 'support/check_inventory_fixture.dart';
import 'support/raw_symlink_fixture.dart';

const _name = 'assets/café/hello.txt';
const _hello =
    '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03';

void main() {
  late Directory base, root;
  late File file;
  final expected = ArchiveInventory({
    _name: (size: 6, mode: 0x1a4, sha256: _hello),
  });
  setUp(() {
    base = Directory(
      Directory.systemTemp
          .createTempSync('directory-test-')
          .resolveSymbolicLinksSync(),
    );
    root = Directory(p.join(base.path, 'installation ü'));
    file = File(p.joinAll([root.path, ..._name.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('hello\n');
  });
  tearDown(() => base.deleteSync(recursive: true));

  test(
    'accepts exactly the pinned files and their parent directories',
    () async {
      await verifyInstallationDirectory(root, expected, compareModes: false);
      expect(file.readAsStringSync(), 'hello\n');
    },
  );
  test(
    'accepts a canonical installation beyond the Windows legacy path limit',
    () async {
      final deep = Directory(
        p.joinAll([
          base.path,
          for (var i = 0; i < 7; i++) 'long installation segment $i café',
        ]),
      )..createSync(recursive: true);
      final moved = root.renameSync(p.join(deep.path, 'installation'));
      expect(moved.path.length, greaterThan(260));
      await verifyInstallationDirectory(moved, expected, compareModes: false);
    },
  );
  test('rejects changed bytes even when the size is unchanged', () async {
    file.writeAsStringSync('world\n');
    await expectLater(
      verifyInstallationDirectory(root, expected, compareModes: false),
      throwsFormatException,
    );
  });
  test('compares physical modes only when requested', () async {
    posix.chmod(file.path, '755');
    await verifyInstallationDirectory(root, expected, compareModes: false);
    await expectLater(
      verifyInstallationDirectory(root, expected, compareModes: true),
      throwsFormatException,
    );
    posix.chmod(file.path, '4755');
    await expectLater(
      verifyInstallationDirectory(root, expected, compareModes: false),
      throwsFormatException,
    );
    posix.chmod(file.path, '644');
    await verifyInstallationDirectory(root, expected, compareModes: true);
  }, skip: Platform.isWindows ? 'POSIX mode fixture' : false);
  for (final change in [
    'missing',
    'extra file',
    'extra directory',
    'size',
    'directory instead of file',
  ]) {
    test('rejects $change', () async {
      switch (change) {
        case 'missing':
          file.deleteSync();
        case 'extra file':
          File(p.join(root.path, 'extra')).writeAsStringSync('');
        case 'extra directory':
          Directory(p.join(root.path, 'extra')).createSync();
        case 'size':
          file.writeAsStringSync('hello');
        case 'directory instead of file':
          file.deleteSync();
          Directory(file.path).createSync();
      }
      await expectLater(
        verifyInstallationDirectory(root, expected, compareModes: false),
        throwsFormatException,
      );
    });
  }
  test('rejects an absent installation root', () async {
    await expectLater(
      verifyInstallationDirectory(
        Directory(p.join(base.path, 'missing')),
        expected,
        compareModes: false,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
  test('rejects an aliased file', () async {
    final target = file.renameSync(p.join(base.path, 'target'));
    if (Platform.isWindows) {
      createWindowsRawLink(file.path, target.path);
    } else {
      Link(file.path).createSync(target.path);
    }
    await expectLater(
      verifyInstallationDirectory(root, expected, compareModes: false),
      throwsFormatException,
    );
  });
  for (final location in ['root', 'parent']) {
    test('rejects a Windows junction $location', () async {
      final original = location == 'root' ? root : file.parent;
      final target = original.renameSync(p.join(base.path, 'junction target'));
      final result = await Process.run(
        windowsInventoryCommand(),
        windowsInventoryJunctionArguments(original.path, target.path),
      );
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      try {
        final metadata = windowsReparseMetadata(original.path);
        expect(metadata.attributes & 0x400, 0x400);
        expect(metadata.tag, 0xa0000003);
        await expectLater(
          verifyInstallationDirectory(root, expected, compareModes: false),
          throwsFormatException,
        );
        expect(
          File(
            p.joinAll([
              target.path,
              if (location == 'root') ...['assets', 'café'],
              'hello.txt',
            ]),
          ).readAsStringSync(),
          'hello\n',
        );
      } finally {
        // Remove the junction itself, never recursively walk its target.
        Link(original.path).deleteSync();
      }
    }, skip: Platform.isWindows ? false : 'Windows reparse fixture');
  }
  test('rejects a Windows file symlink', () async {
    final target = file.renameSync(p.join(base.path, 'file target'));
    createWindowsRawLink(file.path, target.path);
    try {
      final metadata = windowsReparseMetadata(file.path);
      expect(metadata.attributes & 0x400, 0x400);
      expect(metadata.tag, 0xa000000c);
      await expectLater(
        verifyInstallationDirectory(root, expected, compareModes: false),
        throwsFormatException,
      );
      expect(target.readAsStringSync(), 'hello\n');
    } finally {
      Link(file.path).deleteSync();
    }
  }, skip: Platform.isWindows ? false : 'Windows reparse fixture');
}
