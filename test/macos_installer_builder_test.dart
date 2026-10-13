// Filesystem packaging fixtures, not native macOS installation acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

import '../tool/installers/macos/build.dart';
import '../tool/release/native_manifest.dart';

void main() {
  void posixTest(String name, dynamic Function() body, {Object? skip}) => test(
    name,
    body,
    skip: Platform.isWindows ? 'POSIX macOS installer staging fixture' : skip,
  );
  late Directory base, bundle, output;
  late Map<String, Object?> manifest;
  late Map<String, Object?> files;
  void writeManifest() {
    File(p.join(bundle.path, 'manifest.json'))
      ..writeAsStringSync(jsonEncode(manifest));
    posix.chmod(p.join(bundle.path, 'manifest.json'), '644');
  }

  void addFile(String name, {int mode = 0x1a4}) {
    final file = File(p.join(bundle.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('SYNTHETIC fixture only\n');
    posix.chmod(file.path, mode.toRadixString(8));
    files[name] = {
      'size': file.lengthSync(),
      'mode': mode,
      'sha256': sha256.convert(file.readAsBytesSync()).toString(),
    };
  }

  setUp(() {
    base = Directory(
      Directory.systemTemp
          .createTempSync('mac-builder-')
          .resolveSymbolicLinksSync(),
    );
    bundle = Directory(p.join(base.path, 'bundle'))..createSync();
    output = Directory(p.join(base.path, 'output'));
    files = {};
    for (final name in [
      'bin/macos-arm64/archway',
      'native/macos-arm64/libarchway_io.dylib',
      'LICENSE',
      'README.txt',
      'schemas/policy.schema.json',
      'schemas/public-result.schema.json',
      'schemas/export-diagnostics.schema.json',
      'assets/typescript/licenses/pnpm-MIT.txt',
      'assets/typescript/licenses/yaml-ISC.txt',
    ]) {
      addFile(name, mode: name.startsWith('bin/') ? 0x1ed : 0x1a4);
    }
    manifest = {
      'schema_version': 1,
      'target': 'macos-arm64',
      'version': '0.1.0',
      'files': files,
    };
    writeManifest();
  });
  tearDown(() => base.deleteSync(recursive: true));
  posixTest(
    'stages exact payload and unchanged lifecycle without source commit policy',
    () async {
      await buildMacInstaller(
        bundle,
        output,
        stageOnly: true,
        installerDirectory: Directory('tool/installers/macos'),
      );
      final payload = p.join(output.path, 'root/usr/local/lib/archway');
      for (final name in [...files.keys, 'manifest.json']) {
        expect(
          File(p.join(payload, name)).readAsBytesSync(),
          File(p.join(bundle.path, name)).readAsBytesSync(),
        );
        expect(
          File(p.join(payload, name)).statSync().mode & 0xfff,
          File(p.join(bundle.path, name)).statSync().mode & 0xfff,
        );
      }
      final common = File('tool/installers/macos/lifecycle.sh')
          .readAsStringSync();
      for (final name in ['preinstall', 'postinstall']) {
        expect(
          File(p.join(output.path, 'scripts', name)).readAsStringSync(),
          '$common\n$name "\$@"\n',
        );
      }
      expect(
        File(p.join(payload, 'uninstall.sh')).readAsStringSync(),
        '$common\nuninstall "\$@"\n',
      );
      expect(
        File(p.join(output.path, 'installer-evidence.json')).existsSync(),
        isFalse,
      );
    },
  );
  Future<void> stage() => buildMacInstaller(
    bundle,
    output,
    stageOnly: true,
    installerDirectory: Directory('tool/installers/macos'),
  );

  posixTest(
    'rejects each caller policy violation without creating output',
    () async {
      for (final update in <void Function()>[
        () => manifest['target'] = 'linux-x64',
        () => manifest['schema_version'] = 2,
        () => manifest['version'] = '0.1.0-preview',
        () => files.remove('LICENSE'),
        () => (files['bin/macos-arm64/archway'] as Map)['mode'] = 0x1a4,
        () => (files['LICENSE'] as Map)['mode'] = 0x1b6,
      ]) {
        final saved = jsonEncode(manifest);
        update();
        writeManifest();
        await expectLater(stage(), throwsFormatException);
        expect(output.existsSync(), isFalse);
        manifest = jsonDecode(saved) as Map<String, Object?>;
        files = manifest['files'] as Map<String, Object?>;
      }
    },
  );
  posixTest(
    'rejects restricted and reserved paths, including uninstall subtree',
    () async {
      for (final name in [
        'space name',
        '.metadata',
        'uninstall.sh',
        'uninstall.sh/child',
      ]) {
        addFile(name);
        writeManifest();
        await expectLater(stage(), throwsFormatException);
        expect(output.existsSync(), isFalse);
        File(p.join(bundle.path, name)).deleteSync();
        if (name.contains('/'))
          Directory(p.join(bundle.path, 'uninstall.sh')).deleteSync();
        files.remove(name);
      }
    },
  );
  posixTest('rejects bytes, modes, extra files and symlink payloads', () async {
    final license = File(p.join(bundle.path, 'LICENSE'));
    final bytes = license.readAsBytesSync();
    license.writeAsStringSync('tampered');
    await expectLater(stage(), throwsFormatException);
    license.writeAsBytesSync(bytes);
    posix.chmod(license.path, '755');
    await expectLater(stage(), throwsFormatException);
    posix.chmod(license.path, '644');
    final extra = File(p.join(bundle.path, 'extra'))
      ..writeAsStringSync('extra');
    await expectLater(stage(), throwsFormatException);
    extra.deleteSync();
    license.deleteSync();
    Link(license.path).createSync(p.join(bundle.path, 'README.txt'));
    await expectLater(stage(), throwsA(anything));
    expect(output.existsSync(), isFalse);
  });
  posixTest(
    'rejects fresh output inside input directly or through aliased parent',
    () async {
      final alias = Link(p.join(base.path, 'alias'))..createSync(bundle.path);
      final before = bundle
          .listSync(recursive: true)
          .map((e) => e.path)
          .toList();
      for (final parent in [bundle.path, alias.path]) {
        output = Directory(p.join(parent, 'new/stage'));
        await expectLater(stage(), throwsFormatException);
      }
      expect(
        bundle.listSync(recursive: true).map((e) => e.path).toList(),
        before,
      );
    },
  );
  posixTest('preserves existing output and dangling links', () async {
    output.createSync();
    final sentinel = File(p.join(output.path, 'keep'))
      ..writeAsStringSync('keep');
    await expectLater(stage(), throwsFormatException);
    expect(sentinel.readAsStringSync(), 'keep');
    output.deleteSync(recursive: true);
    Link(output.path).createSync(p.join(base.path, 'missing'));
    await expectLater(stage(), throwsFormatException);
    expect(Link(output.path).targetSync(), p.join(base.path, 'missing'));
  });
  posixTest(
    'removes private copied payload after lifecycle input failure',
    () async {
      await expectLater(
        buildMacInstaller(
          bundle,
          output,
          stageOnly: true,
          installerDirectory: Directory(p.join(base.path, 'missing')),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(output.existsSync(), isFalse);
      expect(base.listSync().map((e) => p.basename(e.path)), ['bundle']);
    },
  );
  posixTest('owned inventory includes every copied file and uninstall with actual modes', () async {
    await stage();
    final names = [...files.keys, 'manifest.json', 'uninstall.sh']..sort();
    final lines = File(p.join(output.path, 'scripts/owned.sha256'))
        .readAsLinesSync();
    expect(lines.length, names.length);
    for (var i = 0; i < names.length; i++) {
      final file = File(
        p.join(output.path, 'root/usr/local/lib/archway', names[i]),
      );
      expect(
        lines[i],
        '${sha256.convert(file.readAsBytesSync())} ${(file.statSync().mode & 0xfff).toRadixString(8)} ${names[i]}',
      );
    }
  });
  posixTest('explicit command fixture captures unsigned pkgbuild arguments and evidence', () async {
    await stage();
    final parsed = await readNativeManifest(
      File(p.join(bundle.path, 'manifest.json')),
    );
    await packageMacInstaller(
      output,
      parsed,
      Directory('tool/installers/macos'),
      (command, args) async {
        expect(command, '/usr/bin/pkgbuild');
        expect(args, [
          '--root',
          p.join(output.path, 'root'),
          '--scripts',
          p.join(output.path, 'scripts'),
          '--identifier',
          'org.archway.cli',
          '--version',
          '0.1.0',
          '--install-location',
          '/',
          '--ownership',
          'recommended',
          p.join(output.path, 'archway-0.1.0-macos-arm64-unsigned.pkg'),
        ]);
        File(args.last).writeAsStringSync('command fixture, not a pkg');
        return ProcessResult(0, 0, '', '');
      },
    );
    final evidence = jsonDecode(
      File(p.join(output.path, 'installer-evidence.json')).readAsStringSync(),
    ) as Map;
    expect(evidence['bundle_manifest_sha256'], parsed.manifestSha256);
    expect((evidence['installer_inputs_sha256'] as Map).keys, [
      'build.dart',
      'lifecycle.sh',
    ]);
    expect(
      (evidence['host'] as Map)['system'],
      Platform.isMacOS ? 'Darwin' : Platform.operatingSystem,
    );
    expect(
      evidence['sha256'],
      sha256.convert(utf8.encode('command fixture, not a pkg')).toString(),
    );
    File(p.join(output.path, 'installer-evidence.json')).deleteSync();
    await expectLater(
      packageMacInstaller(
        output,
        parsed,
        Directory('tool/installers/macos'),
        (_, _) async => ProcessResult(0, 9, '', 'fixture compiler failure'),
      ),
      throwsA(isA<ProcessException>()),
    );
    expect(
      File(p.join(output.path, 'installer-evidence.json')).existsSync(),
      isFalse,
    );
  });
  posixTest(
    'native build refuses actual non-macOS host before any mutation',
    () async {
      await expectLater(
        buildMacInstaller(
          bundle,
          output,
          installerDirectory: Directory('tool/installers/macos'),
        ),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);
    },
    skip: Platform.isMacOS ? 'Non-macOS host control' : false,
  );
  posixTest('restricted child umask keeps package directories traversable and stage private', () async {
    final result = await Process.run('/bin/sh', [
      '-c',
      r'umask 077; exec "$@"',
      'mac-builder-umask-fixture',
      Platform.resolvedExecutable,
      'run',
      File('tool/installers/macos/build.dart').absolute.path,
      '--bundle',
      bundle.path,
      '--output',
      output.path,
      '--stage-only',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(output.statSync().mode & 0xfff, 0x1c0);
    for (final directory
        in output.listSync(recursive: true).whereType<Directory>()) {
      expect(directory.statSync().mode & 0xfff, 0x1ed, reason: directory.path);
    }
    expect(
      File(p.join(output.path, 'scripts/owned.sha256')).statSync().mode & 0xfff,
      0x1a4,
    );
  });
  posixTest(
    'shared producer manifest mode precondition rejects 0755 before staging',
    () async {
      posix.chmod(p.join(bundle.path, 'manifest.json'), '755');
      await expectLater(stage(), throwsFormatException);
      expect(output.existsSync(), isFalse);
    },
  );
}
