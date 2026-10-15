import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/check_inventory_fixture.dart';
import 'support/native_file_fixtures.dart';

void main() {
  final native = Platform.isWindows && Abi.current() == Abi.windowsX64;
  test(
    'deletion-only lock and entry removal reject unsupported hosts',
    () {
      expect(
        () => DeleteDeniedWindowsFileLock('unused'),
        throwsUnsupportedError,
      );
      expect(
        () => removeWindowsDirectoryEntry('unused'),
        throwsUnsupportedError,
      );
    },
    skip: native ? 'Non-native Windows installer fixture host control' : false,
  );

  test(
    'Windows deletion lock permits reads and writes but denies deletion',
    () {
      final root = Directory.systemTemp.createTempSync('archway-delete-lock-');
      final file = File(p.join(root.path, 'obsolete café..txt'))
        ..writeAsStringSync('stale');
      try {
        final lock = DeleteDeniedWindowsFileLock(file.path);
        try {
          expect(file.readAsStringSync(), 'stale');
          file.writeAsStringSync('changed');
          expect(file.readAsStringSync(), 'changed');
          expect(
            () => file.deleteSync(),
            throwsA(
              isA<FileSystemException>().having(
                (e) => e.osError?.errorCode,
                'sharing violation',
                32,
              ),
            ),
          );
          expect(file.readAsStringSync(), 'changed');
        } finally {
          lock.close();
        }
        lock.close();
        file.deleteSync();
        expect(file.existsSync(), isFalse);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: native ? false : 'Native Windows deletion-only sharing fixture',
  );

  test(
    'Windows directory entry removal never traverses a junction target',
    () {
      final root = Directory.systemTemp.createTempSync(
        'archway-entry-removal-',
      );
      final target = Directory(p.join(root.path, 'target café'))..createSync();
      final survivor = File(p.join(target.path, 'keep'))
        ..writeAsStringSync('foreign');
      final junction = p.join(root.path, 'obsolete junction');
      try {
        final result = Process.runSync(
          windowsInventoryCommand(),
          windowsInventoryJunctionArguments(junction, target.path),
        );
        expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
        expect(windowsReparseMetadata(junction).tag, 0xa0000003);
        removeWindowsDirectoryEntry(junction);
        expect(
          FileSystemEntity.typeSync(junction, followLinks: false),
          FileSystemEntityType.notFound,
        );
        expect(survivor.readAsStringSync(), 'foreign');
        expect(
          () => removeWindowsDirectoryEntry(target.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(survivor.readAsStringSync(), 'foreign');
      } finally {
        // If entry cleanup fails, preserve the temporary tree rather than ever
        // invoking recursive cleanup on a surviving junction.
        if (FileSystemEntity.typeSync(junction, followLinks: false) !=
            FileSystemEntityType.notFound) {
          removeWindowsDirectoryEntry(junction);
        }
        root.deleteSync(recursive: true);
      }
    },
    skip: native
        ? false
        : 'Native Windows nonrecursive junction removal fixture',
  );
}
