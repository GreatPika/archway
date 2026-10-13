import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/flutter_sdk_copy.dart';

void main() {
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
