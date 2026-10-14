// Filesystem packaging fixtures, not native macOS installation acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

import 'alias_hop_recheck_process_smoke.dart' as alias;
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

  // Relocated scripts exercise real shell ownership logic. Host/stat/pkgutil
  // substitutions are fixture-only and do not establish native macOS acceptance.
  String installedRoot() => p.join(base.path, 'system/usr/local/lib/archway');
  String commandPath() => p.join(base.path, 'system/usr/local/bin/archway');
  Future<({int code, List<int> out, List<int> err})> script(
    String name, {
    bool fixtureHost = true,
  }) async {
    final original = name == 'uninstall'
        ? p.join(output.path, 'root/usr/local/lib/archway/uninstall.sh')
        : p.join(output.path, 'scripts', name);
    var contents = File(original)
        .readAsStringSync()
        .replaceAll('/usr/local', p.join(base.path, 'system/usr/local'));
    if (fixtureHost) {
      final host = Process.runSync('/usr/bin/uname', [
        '-s',
      ]).stdout.toString().trim();
      final cpu = Process.runSync('/usr/bin/uname', [
        '-m',
      ]).stdout.toString().trim();
      contents = contents.replaceAll('Darwin:arm64', '$host:$cpu');
    }
    if (!Platform.isMacOS) {
      contents = contents.replaceAll("stat -f '%Op'", "stat -c '%a'");
    }
    final pkgutil = File(p.join(base.path, 'pkgutil'))
      ..writeAsStringSync(
        '#!/bin/sh\n[ -f "${p.join(base.path, 'receipt')}" ]\n',
      );
    posix.chmod(pkgutil.path, '755');
    final fixture = File(p.join(output.path, 'scripts', 'fixture-$name'))
      ..writeAsStringSync(
        contents.replaceAll('/usr/sbin/pkgutil', pkgutil.path),
      );
    return alias.capture('/bin/sh', [fixture.path, 'fixture.pkg', '/', '/']);
  }

  void extractPayload() {
    final source = Directory(p.join(output.path, 'root/usr/local/lib/archway'));
    for (final entry in source.listSync(recursive: true, followLinks: false)) {
      final destination = p.join(
        installedRoot(),
        p.relative(entry.path, from: source.path),
      );
      if (entry is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entry is File) {
        File(destination).parent.createSync(recursive: true);
        entry.copySync(destination);
        posix.chmod(
          destination,
          (entry.statSync().mode & 0xfff).toRadixString(8),
        );
      } else {
        throw StateError('Unexpected staged fixture entry: ${entry.path}');
      }
    }
  }

  Future<Directory> install() async {
    await stage();
    final before = await script('preinstall');
    expect(before.code, 0, reason: utf8.decode(before.err));
    extractPayload();
    final after = await script('postinstall');
    expect(after.code, 0, reason: utf8.decode(after.err));
    File(p.join(base.path, 'receipt')).writeAsStringSync('fixture receipt');
    return Directory(installedRoot());
  }

  posixTest('staged lifecycle registers command and owned inventory', () async {
    final root = await install();
    expect(
      Link(commandPath()).resolveSymbolicLinksSync(),
      p.join(root.path, 'bin/macos-arm64/archway'),
    );
    expect(
      File(p.join(root.path, '.archway-owned.sha256')).existsSync(),
      isTrue,
    );
  });
  posixTest('staged lifecycle upgrade removes stale owned files and preserves foreign files', () async {
    addFile('assets/typescript/helper.cjs');
    writeManifest();
    final root = await install();
    final personal = File(p.join(root.path, 'personal.txt'))
      ..writeAsStringSync('keep me');
    File(p.join(bundle.path, 'assets/typescript/helper.cjs')).deleteSync();
    files.remove('assets/typescript/helper.cjs');
    manifest['version'] = '0.1.1';
    writeManifest();
    output = Directory(p.join(base.path, 'upgrade'));
    await install();
    expect(
      File(p.join(root.path, 'assets/typescript/helper.cjs')).existsSync(),
      isFalse,
    );
    expect(personal.readAsStringSync(), 'keep me');
  });
  posixTest('staged lifecycle refuses modified owned files and incoming foreign collisions', () async {
    final root = await install();
    final owned = File(p.join(root.path, 'LICENSE'))
      ..writeAsStringSync('user modification');
    expect((await script('preinstall')).code, isNot(0));
    expect(owned.readAsStringSync(), 'user modification');
    File(p.join(bundle.path, 'LICENSE')).copySync(owned.path);
    final foreign = File(p.join(root.path, 'new.txt'))
      ..writeAsStringSync('user file');
    addFile('new.txt');
    writeManifest();
    output = Directory(p.join(base.path, 'upgrade'));
    await stage();
    expect((await script('preinstall')).code, isNot(0));
    expect(foreign.readAsStringSync(), 'user file');
  });
  posixTest('staged lifecycle uninstall preserves foreign and modified files and replaced command', () async {
    final root = await install();
    final personal = File(p.join(root.path, 'personal.txt'))
      ..writeAsStringSync('keep me');
    final owned = File(p.join(root.path, 'LICENSE'))
      ..writeAsStringSync('modified by user');
    Link(commandPath()).deleteSync();
    final command = File(commandPath())..writeAsStringSync('another command');
    final result = await script('uninstall');
    expect(result.code, 0, reason: utf8.decode(result.err));
    expect(personal.readAsStringSync(), 'keep me');
    expect(owned.readAsStringSync(), 'modified by user');
    expect(command.readAsStringSync(), 'another command');
    expect(Directory(p.join(root.path, 'bin')).existsSync(), isFalse);
    expect(
      File(p.join(root.path, '.archway-owned.sha256')).existsSync(),
      isFalse,
    );
  });
  posixTest(
    'staged lifecycle clean uninstall removes owned root and command',
    () async {
      final root = await install();
      final result = await script('uninstall');
      expect(result.code, 0, reason: utf8.decode(result.err));
      expect(root.existsSync(), isFalse);
      expect(Link(commandPath()).existsSync(), isFalse);
    },
  );
  posixTest(
    'staged lifecycle malformed inventory refuses removal before mutation',
    () async {
      final root = await install();
      final inventory = File(p.join(root.path, '.archway-owned.sha256'));
      inventory.writeAsStringSync(
        '${'a' * 64} 644 ../../foreign\n',
        mode: FileMode.append,
      );
      expect((await script('uninstall')).code, isNot(0));
      expect(
        File(p.join(root.path, 'bin/macos-arm64/archway')).existsSync(),
        isTrue,
      );
      expect(Link(commandPath()).existsSync(), isTrue);
    },
  );
  posixTest(
    'staged lifecycle missing payload cannot register command or ownership',
    () async {
      await stage();
      expect((await script('preinstall')).code, 0);
      expect(Directory(installedRoot()).existsSync(), isFalse);
      extractPayload();
      File(p.join(installedRoot(), 'bin/macos-arm64/archway')).deleteSync();
      expect((await script('postinstall')).code, isNot(0));
      expect(
        File(p.join(installedRoot(), '.archway-owned.sha256')).existsSync(),
        isFalse,
      );
      expect(Link(commandPath()).existsSync(), isFalse);
    },
  );
  posixTest(
    'staged lifecycle refuses non-macOS host before mutation',
    () async {
      await stage();
      expect((await script('preinstall', fixtureHost: false)).code, isNot(0));
      expect(Directory(p.join(base.path, 'system')).existsSync(), isFalse);
    },
    skip: Platform.isMacOS ? 'Non-macOS host control' : false,
  );
  posixTest(
    'staged lifecycle refuses foreign commands and aliased parents',
    () async {
      await stage();
      final directory = Directory(p.dirname(commandPath()))
        ..createSync(recursive: true);
      final foreign = File(commandPath())
        ..writeAsStringSync('foreign executable');
      expect((await script('preinstall')).code, isNot(0));
      expect(foreign.readAsStringSync(), 'foreign executable');
      foreign.deleteSync();
      final command = Link(commandPath())
        ..createSync(p.join(base.path, 'missing-command'));
      expect((await script('preinstall')).code, isNot(0));
      command.deleteSync();
      directory.deleteSync();
      final other = Directory(p.join(base.path, 'other'))..createSync();
      Link(directory.path).createSync(other.path);
      expect((await script('preinstall')).code, isNot(0));
      expect(other.listSync(), isEmpty);
    },
  );
  posixTest('staged lifecycle refuses foreign root without mutation', () async {
    await stage();
    final root = Directory(installedRoot())..createSync(recursive: true);
    final foreign = File(p.join(root.path, 'user-file'))
      ..writeAsStringSync('keep me');
    expect((await script('preinstall')).code, isNot(0));
    expect(foreign.readAsStringSync(), 'keep me');
    expect(root.listSync().map((e) => e.path), [foreign.path]);
  });
  posixTest(
    'staged lifecycle upgrade refuses changed mode and uninstall preserves it',
    () async {
      final root = await install();
      final executable = File(p.join(root.path, 'bin/macos-arm64/archway'));
      posix.chmod(executable.path, '644');
      expect((await script('preinstall')).code, isNot(0));
      expect(executable.statSync().mode & 0xfff, 0x1a4);
      expect((await script('uninstall')).code, 0);
      expect(executable.existsSync(), isTrue);
      expect(executable.statSync().mode & 0xfff, 0x1a4);
    },
  );
  posixTest(
    'staged lifecycle postinstall refuses mode loss before registration',
    () async {
      await stage();
      expect((await script('preinstall')).code, 0);
      extractPayload();
      posix.chmod(p.join(installedRoot(), 'bin/macos-arm64/archway'), '644');
      expect((await script('postinstall')).code, isNot(0));
      expect(
        File(p.join(installedRoot(), '.archway-owned.sha256')).existsSync(),
        isFalse,
      );
      expect(Link(commandPath()).existsSync(), isFalse);
    },
  );

  posixTest(
    'rejects each caller policy violation without creating output',
    () async {
      final license = File(p.join(bundle.path, 'LICENSE'));
      final originalLicense = license.readAsBytesSync();
      final executable = File(p.join(bundle.path, 'bin/macos-arm64/archway'));
      for (final update in <void Function()>[
        () => manifest['target'] = 'linux-x64',
        () => manifest['schema_version'] = 2,
        () => manifest['version'] = '0.1.0-preview',
        () {
          files.remove('LICENSE');
          license.deleteSync();
        },
        () {
          (files['bin/macos-arm64/archway'] as Map)['mode'] = 0x1a4;
          posix.chmod(executable.path, '644');
        },
        () {
          (files['LICENSE'] as Map)['mode'] = 0x1b6;
          posix.chmod(license.path, '666');
        },
      ]) {
        final saved = jsonEncode(manifest);
        update();
        writeManifest();
        await expectLater(stage(), throwsFormatException);
        expect(output.existsSync(), isFalse);
        manifest = jsonDecode(saved) as Map<String, Object?>;
        files = manifest['files'] as Map<String, Object?>;
        license.writeAsBytesSync(originalLicense);
        posix.chmod(license.path, '644');
        posix.chmod(executable.path, '755');
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
        expect(args.length, 13);
        expect(
          args.last,
          p.join(output.path, 'archway-0.1.0-macos-arm64-unsigned.pkg'),
        );
        expect(
          {for (var i = 0; i < args.length - 1; i += 2) args[i]: args[i + 1]},
          {
            '--root': p.join(output.path, 'root'),
            '--scripts': p.join(output.path, 'scripts'),
            '--identifier': 'org.archway.cli',
            '--version': '0.1.0',
            '--install-location': '/',
            '--ownership': 'recommended',
          },
        );
        File(args.last).writeAsStringSync('command fixture, not a pkg');
        return ProcessResult(0, 0, '', '');
      },
    );
    final evidence = jsonDecode(
      File(p.join(output.path, 'installer-evidence.json')).readAsStringSync(),
    ) as Map;
    expect(evidence['bundle_manifest_sha256'], parsed.manifestSha256);
    expect(evidence['installer_inputs_sha256'], {
      for (final name in ['build.dart', 'lifecycle.sh'])
        name: sha256
            .convert(
              File(p.join('tool/installers/macos', name)).readAsBytesSync(),
            )
            .toString(),
    });
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
