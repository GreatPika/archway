import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/flutter_sdk_copy.dart';

void main() {
  test(
    'Windows hardlink spelling keeps drive, UNC and extended identities',
    () {
      expect(
        flutterWindowsNativePath(r'C:\Flutter café SDK\bin\dart.exe'),
        r'\\?\C:\Flutter café SDK\bin\dart.exe',
      );
      expect(
        flutterWindowsNativePath(r'\\server\share\Flutter café SDK\dart.exe'),
        r'\\?\UNC\server\share\Flutter café SDK\dart.exe',
      );
      expect(
        flutterWindowsNativePath(r'\\?\C:\deep\dart.exe'),
        r'\\?\C:\deep\dart.exe',
      );
      expect(
        flutterWindowsNativePath(r'\\?\UNC\server\share\deep\dart.exe'),
        r'\\?\UNC\server\share\deep\dart.exe',
      );
    },
  );
  test('Windows deep source and destination remain real isolated hardlinks', () {
    final base = Directory.systemTemp.createTempSync('flutter-deep-copy-');
    addTearDown(() => base.deleteSync(recursive: true));
    // Keep the enumerated directory below MAX_PATH, but both native hardlink
    // file arguments above it. This isolates CreateHardLinkW from enumeration.
    final source = Directory(
      p.join(
        base.path,
        'source'.padRight((220 - base.path.length - 1).clamp(6, 220), 's'),
      ),
    )..createSync();
    expect(source.path.length, lessThan(260));
    final name = '${'fixture'.padRight(160, 'f')}.dart';
    final original = File(p.join(source.path, name))
      ..writeAsStringSync('original');
    final destination = Directory(p.join(base.path, 'Flutter café SDK'));
    // An equally deep destination needs no directory enumeration during copy.
    final copy = Directory(
      p.join(destination.path, 'nested'.padRight(150, 'd')),
    );
    destination.createSync();
    expect(original.path.length, greaterThan(260));
    expect(p.join(copy.path, name).length, greaterThan(260));
    copyFlutterSdk(source, copy);
    final duplicate = File(p.join(copy.path, name));
    duplicate.writeAsStringSync('linked');
    expect(original.readAsStringSync(), 'linked');
    duplicate.deleteSync();
    duplicate.writeAsStringSync('replacement');
    expect(original.readAsStringSync(), 'linked');
  }, skip: !Platform.isWindows ? 'Requires native Windows hardlinks.' : false);
  test(
    'Flutter copy hardlinks files, preserves links and isolates replacements',
    () {
      final base = Directory.systemTemp.createTempSync('flutter-copy-test-');
      addTearDown(() => base.deleteSync(recursive: true));
      final source = Directory(p.join(base.path, 'source'))..createSync();
      final original = File(p.join(source.path, 'dart'))
        ..writeAsStringSync('original');
      Directory(p.join(source.path, '.git')).createSync();
      File(p.join(source.path, '.git', 'config')).writeAsStringSync('ignored');
      // Windows symlink creation requires an independently enabled host capability.
      if (!Platform.isWindows)
        Link(p.join(source.path, 'alias')).createSync('dart');
      final copy = Directory(p.join(base.path, 'Flutter café SDK'));
      copyFlutterSdk(source, copy);
      final duplicate = File(p.join(copy.path, 'dart'));
      duplicate.writeAsStringSync('linked');
      expect(original.readAsStringSync(), 'linked');
      duplicate.deleteSync();
      duplicate.writeAsStringSync('replacement');
      expect(original.readAsStringSync(), 'linked');
      expect(Directory(p.join(copy.path, '.git')).existsSync(), false);
      if (!Platform.isWindows) {
        expect(Link(p.join(copy.path, 'alias')).targetSync(), 'dart');
        makeFlutterLauncherExecutable(duplicate);
        expect(duplicate.statSync().mode & 0x1ff, 0x1ed);
      }
      expect(
        () => copyFlutterSdk(source, copy),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
