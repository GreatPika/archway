import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support/native_file_fixtures.dart';

void main() {
  test('native file writer fixture starts through the Dart CLI', () {
    final root = Directory.systemTemp.createTempSync('archway-file-child-');
    try {
      final file = File('${root.path}${Platform.pathSeparator}output');
      final result = Process.runSync(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        'test/support/native_file_fixture_child.dart',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(file.readAsStringSync(), 'changed');
    } finally {
      root.deleteSync(recursive: true);
    }
  });
  test('RawPathFixtureTest.test_native_invalid_encoding_is_not_a_replacement_character', () {
    final fixture = MalformedNativeFile('fixture', 'bad');
    expect(fixture.windowsPath.codeUnits, [
      ...'fixture${Platform.pathSeparator}bad'.codeUnits,
      0xdcff,
    ]);
    expect(fixture.posixPath, [
      ...utf8.encode('fixture${Platform.pathSeparator}bad'),
      0xff,
    ]);
    expect(fixture.windowsPath, isNot(contains('\uFFFD')));
  });
  test(
    'WindowsOutputLockTest.test_real_sharing_conflict_prevents_truncation_and_releases',
    () {
      final root = Directory.systemTemp.createTempSync('archway-sharing-');
      final file = File('${root.path}\\output café')
        ..writeAsStringSync('original');
      try {
        final lock = ExclusiveWindowsFileLock(file.path);
        try {
          final attempted = Process.runSync(Platform.resolvedExecutable, [
            '--suppress-analytics',
            'run',
            'test/support/native_file_fixture_child.dart',
            file.path,
          ]);
          expect(attempted.exitCode, isNot(0));
          expect(attempted.stderr, contains('errno = 32'));
          expect(
            () => file.openSync(mode: FileMode.write),
            throwsA(
              isA<FileSystemException>().having(
                (e) => e.osError?.errorCode,
                'sharing violation',
                32,
              ),
            ),
          );
        } finally {
          lock.close();
        }
        lock.close();
        expect(file.readAsStringSync(), 'original');
        file.writeAsStringSync('released');
        expect(file.readAsStringSync(), 'released');
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? false
        : 'Win32 sharing-mode fixture is Windows-specific',
  );
  test('resource creation failure preserves the existing file', () {
    final root = Directory.systemTemp.createTempSync(
      'archway-resource-failure-',
    );
    final file = File('${root.path}${Platform.pathSeparator}input')
      ..writeAsStringSync('keep');
    try {
      expect(
        () => createNonregularResource(file.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.readAsStringSync(), 'keep');
    } finally {
      root.deleteSync(recursive: true);
    }
  });
  test('NonregularResourceTest.test_resource_exists_but_is_not_a_file_and_can_be_removed', () {
    final root = Directory.systemTemp.createTempSync('archway-resource-');
    final path = '${root.path}${Platform.pathSeparator}input';
    try {
      createNonregularResource(path);
      if (Platform.isWindows) {
        expect(Directory(path).existsSync(), isTrue);
      } else {
        final result = Process.runSync('test', ['-p', path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      removeNonregularResource(path);
      expect(FileSystemEntity.typeSync(path), FileSystemEntityType.notFound);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
  test('RawPathFixtureTest.test_real_filesystem_rejects_malformed_names_on_apfs_or_roundtrips_them_separately', () {
    final root = Directory.systemTemp.createTempSync('archway-native-fixture-');
    try {
      final fixture = MalformedNativeFile(root.path, 'bad');
      if (Platform.isMacOS) {
        expect(
          () => fixture.create(utf8.encode('malformed')),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'EILSEQ on APFS',
              92,
            ),
          ),
        );
        expect(root.listSync(), isEmpty);
        final replacement = File('${root.path}/bad\uFFFD')
          ..writeAsStringSync('valid');
        expect(replacement.readAsStringSync(), 'valid');
        return;
      }
      fixture.create(utf8.encode('malformed'));
      try {
        if (!Platform.isWindows) {
          final listing = Process.runSync('find', [
            root.path,
            '-type',
            'f',
            '-print0',
          ], stdoutEncoding: null);
          expect(listing.exitCode, 0);
          expect(listing.stdout, [...utf8.encode('${root.path}/bad'), 0xff, 0]);
        } else {
          // Independently enumerate the name with Win32, not the creation API.
          final api = DynamicLibrary.open('kernel32.dll');
          final first = api
              .lookupFunction<
                Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>),
                Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>)
              >('FindFirstFileW');
          final close = api
              .lookupFunction<
                Int32 Function(Pointer<Void>),
                int Function(Pointer<Void>)
              >('FindClose');
          final pattern = '${root.path}\\bad*'.toNativeUtf16();
          final data = calloc<Uint8>(592); // WIN32_FIND_DATAW, Windows x64.
          try {
            final handle = first(pattern, data.cast());
            expect(handle.address, isNot(-1));
            expect(handle.address, isNot(0xffffffffffffffff));
            try {
              expect((data + 44).cast<Uint16>().asTypedList(5), [
                98,
                97,
                100,
                0xdcff,
                0,
              ]);
            } finally {
              expect(close(handle), isNot(0));
            }
          } finally {
            calloc.free(data);
            malloc.free(pattern);
          }
        }
        expect(fixture.existsExactly(), isTrue);
        final replacement = File(
          '${root.path}${Platform.pathSeparator}bad\uFFFD',
        );
        replacement.writeAsStringSync('valid');
        expect(fixture.read(), utf8.encode('malformed'));
        expect(replacement.readAsStringSync(), 'valid');
      } finally {
        fixture.delete();
      }
      expect(fixture.existsExactly(), isFalse);
      expect(
        File('${root.path}${Platform.pathSeparator}bad\uFFFD')
            .readAsStringSync(),
        'valid',
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
