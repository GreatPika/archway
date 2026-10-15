import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_assembly_init_probe.dart';

void main() {
  late Directory base, source, bundle;
  const assets = [
    'helper.cjs',
    'package.json',
    'README.md',
    'licenses/notice.txt',
    'vendor/pkg/nested.js',
  ];
  File at(Directory root, String name) => File(p.join(root.path, name));
  void write(Directory root, String name, String contents) {
    final file = at(root, name);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  setUp(() {
    base = Directory.systemTemp.createTempSync('assembly-layout-');
    source = Directory(p.join(base.path, 'sources'))..createSync();
    bundle = Directory(p.join(base.path, 'installation'))..createSync();
    for (final name in assets) {
      write(source, name, 'owned $name');
      write(bundle, 'assets/typescript/$name', 'owned $name');
    }
    write(source, 'ignored.ts', 'not copied');
    write(source, 'other/ignored.cjs', 'not copied');
    write(bundle, 'bin/linux-x64/archway', 'fixture executable');
    write(bundle, 'native/linux-x64/libarchway_io.so', 'fixture bridge');
  });
  tearDown(() => base.deleteSync(recursive: true));
  void verify() =>
      verifyAssembly(bundle, source, 'linux-x64', 'libarchway_io.so');

  test(
    'exact ordinary layout yields only the assembler-selected inventory',
    () {
      final result = verifyAssembly(
        bundle,
        source,
        'linux-x64',
        'libarchway_io.so',
      );
      expect(result.expected, {
        'bin/linux-x64/archway',
        'native/linux-x64/libarchway_io.so',
        'assets/typescript/helper.cjs',
        'assets/typescript/package.json',
        'assets/typescript/README.md',
        'assets/typescript/licenses/notice.txt',
        'assets/typescript/vendor/pkg/nested.js',
      });
      expect(
        result.binary.path,
        p.join(bundle.path, 'bin', 'linux-x64', 'archway'),
      );
    },
  );
  test('owned glob selection includes extension-only basenames', () {
    for (final name in ['.cjs', '.json', '.md']) {
      write(source, name, 'owned $name');
      write(bundle, 'assets/typescript/$name', 'owned $name');
    }
    final result = verifyAssembly(
      bundle,
      source,
      'linux-x64',
      'libarchway_io.so',
    );
    expect(
      result.expected,
      containsAll([
        'assets/typescript/.cjs',
        'assets/typescript/.json',
        'assets/typescript/.md',
      ]),
    );
  });
  test('missing fixed-layout native payload is rejected', () {
    at(bundle, 'bin/linux-x64/archway').deleteSync();
    expect(verify, throwsStateError);
  });
  test('extra installation root and wrong-target payload are rejected', () {
    write(bundle, 'extra', 'unexpected');
    expect(verify, throwsStateError);
    at(bundle, 'extra').deleteSync();
    write(bundle, 'bin/macos-arm64/archway', 'unexpected');
    expect(verify, throwsStateError);
  });
  test('extra, missing and modified owned assets are rejected', () {
    write(bundle, 'assets/typescript/extra.cjs', 'unexpected');
    expect(verify, throwsStateError);
    at(bundle, 'assets/typescript/extra.cjs').deleteSync();
    at(bundle, 'assets/typescript/helper.cjs').deleteSync();
    expect(verify, throwsStateError);
    write(bundle, 'assets/typescript/helper.cjs', 'changed');
    expect(verify, throwsStateError);
  });
  test('native payload and owned asset symlinks are refused', () {
    for (final name in [
      'bin/linux-x64/archway',
      'assets/typescript/helper.cjs',
    ]) {
      final file = at(bundle, name);
      final saved = file.readAsBytesSync();
      final target = at(base, 'target')..writeAsBytesSync(saved);
      file.deleteSync();
      Link(file.path).createSync(target.path);
      try {
        expect(verify, throwsStateError);
      } finally {
        Link(file.path).deleteSync();
        file.writeAsBytesSync(saved);
      }
    }
  });
}
