// Synthetic orchestration checks only, not native installer acceptance.
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:posix/posix.dart' as posix;

import '../tool/ci/native_linux_installer_probe.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  void linuxTest(String name, dynamic Function() body) => test(
    name,
    body,
    skip: Platform.isLinux
        ? false
        : 'Requires Linux synthetic installer orchestration.',
  );
  linuxTest('compiler discovery skips inert PATH files and rejects no executable', () async {
    final base = Directory.systemTemp.createTempSync('linux-compiler-path-');
    addTearDown(() => base.deleteSync(recursive: true));
    final inert = Directory(p.join(base.path, 'inert'))..createSync();
    final valid = Directory(p.join(base.path, 'valid'))..createSync();
    final inactive = File(p.join(inert.path, 'dpkg-deb'))
      ..writeAsStringSync('not executable');
    posix.chmod(inactive.path, '644');
    final executable = File(p.join(valid.path, 'dpkg-deb'))
      ..writeAsStringSync(
        '#!/bin/sh\necho executable-compiler-selected\nexit 42\n',
      );
    posix.chmod(executable.path, '755');
    final bundle = Directory(p.join(base.path, 'bundle'))..createSync();
    final driver = File(p.join(base.path, 'driver.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        "import '${File('tool/ci/native_linux_installer_probe.dart').absolute.uri}';\n"
        "Future<void> main(List<String> args) async { try {\n"
        "await runLinuxInstallerProbe(builderDart: File(Platform.resolvedExecutable), "
        "repository: Directory(args[0]), bundle: Directory(args[1]), output: Directory(args[2]), "
        "expectedCommit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', privilege: [], inspect: (_, _) async => {});"
        "} catch (error) { stderr.write(error); exitCode = 17; } }",
      );
    for (final hasExecutable in [true, false]) {
      final output = Directory(p.join(base.path, 'output-$hasExecutable'));
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          driver.path,
          Directory.current.path,
          bundle.path,
          output.path,
        ],
        environment: {
          'PATH': hasExecutable ? '${inert.path}:${valid.path}' : inert.path,
        },
      );
      expect(result.exitCode, 17);
      if (hasExecutable) {
        expect(
          File(p.join(output.path, 'linux-0.stdout.log')).readAsStringSync(),
          'executable-compiler-selected\n',
        );
      } else {
        expect(
          result.stderr,
          contains('Native dpkg-deb compiler is unavailable'),
        );
        expect(output.listSync(), isEmpty);
      }
    }
  });
  linuxTest('synthetic upgrade inspects final bytes, preserves foreign files and receipts', () async {
    final base = Directory.systemTemp.createTempSync('linux-probe-test-');
    addTearDown(() => base.deleteSync(recursive: true));
    final bundle = makeBundle(base);
    final before = File(p.join(bundle.path, 'manifest.json')).readAsBytesSync();
    final wrapper = makeWrapper(base);
    var inspected = false;
    final output = Directory(p.join(base.path, 'evidence'));
    final proof = await runLinuxInstallerProbe(
      builderDart: File(Platform.resolvedExecutable),
      repository: Directory.current,
      bundle: bundle,
      output: output,
      expectedCommit: 'a' * 40,
      privilege: [Platform.resolvedExecutable, wrapper.path],
      inspect: (binary, installation) async {
        inspected = true;
        expect(binary.readAsStringSync(), 'synthetic bin/linux-x64/archway\n');
        expect(
          File(p.join(installation.path, 'obsolete/installer-probe..txt'))
              .existsSync(),
          isFalse,
        );
        return {'scope': 'synthetic callback only'};
      },
    );
    expect(inspected, isTrue);
    expect(proof['cases'], [
      'install-old',
      'upgrade-final',
      'installed-command',
      'remove',
      'foreign-preserved',
    ]);
    expect(
      File(p.join(bundle.path, 'manifest.json')).readAsBytesSync(),
      before,
    );
    final commands = proof['commands'] as List;
    expect((commands.last as Map)['arguments'], contains('cleanup'));
    expect(
      File(p.join(output.path, 'dpkg.log')).readAsStringSync(),
      contains('--remove'),
    );
  });
  linuxTest('primary inspection failure survives cleanup failure with durable logs', () async {
    final base = Directory.systemTemp.createTempSync('linux-probe-failure-');
    addTearDown(() => base.deleteSync(recursive: true));
    final bundle = makeBundle(base);
    final wrapper = makeWrapper(base);
    wrapper.writeAsStringSync(
      wrapper.readAsStringSync().replaceFirst(
        "if (args.first != 'dpkg') {",
        "if (args.last == 'cleanup') { File('${base.path}/root').writeAsStringSync(args[2]); stderr.write('synthetic cleanup failed'); exitCode = 19; return; }\n  if (args.first != 'dpkg') {",
      ),
    );
    final output = Directory(p.join(base.path, 'evidence'));
    try {
      await expectLater(
        runLinuxInstallerProbe(
          builderDart: File(Platform.resolvedExecutable),
          repository: Directory.current,
          bundle: bundle,
          output: output,
          expectedCommit: 'a' * 40,
          privilege: [Platform.resolvedExecutable, wrapper.path],
          inspect: (_, _) async =>
              throw StateError('primary inspection failure'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'primary',
            'primary inspection failure',
          ),
        ),
      );
      final logs = output.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.stderr.log'),
      );
      expect(
        logs.any(
          (f) => f.readAsStringSync().contains('synthetic cleanup failed'),
        ),
        isTrue,
      );
    } finally {
      final root = Directory(
        File(p.join(base.path, 'root')).readAsStringSync(),
      );
      expect(p.basename(root.path), startsWith('archway installer '));
      root.deleteSync(
        recursive: true,
      ); // All bytes are unprivileged synthetic fixtures.
    }
  });

  linuxTest(
    'fixture rejects root aliases and foreign destination aliases',
    () async {
      final base = Directory.systemTemp.createTempSync('linux-fixture-');
      addTearDown(() => base.deleteSync(recursive: true));
      final root = Directory(p.join(base.path, 'archway installer owned'))
        ..createSync();
      final outside = Directory(p.join(base.path, 'outside'))..createSync();
      final token = 'b' * 64;
      File(p.join(root.path, '.archway-installer-owner'))
          .writeAsStringSync(token);
      final alias = Link(p.join(base.path, 'archway installer alias'))
        ..createSync(root.path);
      Future<ProcessResult> invoke(String path, String action) => Process.run(
        Platform.resolvedExecutable,
        ['tool/ci/linux_installer_fixture.dart', path, token, action],
      );
      expect((await invoke(alias.path, 'cleanup')).exitCode, 1);
      Directory(p.join(root.path, 'system/usr/lib'))
          .createSync(recursive: true);
      Link(p.join(root.path, 'system/usr/lib/archway'))
          .createSync(outside.path);
      expect((await invoke(root.path, 'foreign')).exitCode, 1);
      expect(outside.listSync(), isEmpty);
      expect((await invoke(root.path, 'cleanup')).exitCode, 0);
      expect(outside.existsSync(), isTrue);
    },
  );

  linuxTest(
    'evidence parent alias is rejected before writing inside input',
    () async {
      final base = Directory.systemTemp.createTempSync('linux-output-alias-');
      addTearDown(() => base.deleteSync(recursive: true));
      final bundle = makeBundle(base);
      final alias = Link(p.join(base.path, 'alias'))..createSync(bundle.path);
      await expectLater(
        runLinuxInstallerProbe(
          builderDart: File(Platform.resolvedExecutable),
          repository: Directory.current,
          bundle: bundle,
          output: Directory(p.join(alias.path, 'evidence')),
          expectedCommit: 'a' * 40,
          privilege: const [],
          inspect: (_, _) async => {},
        ),
        throwsFormatException,
      );
      expect(Directory(p.join(bundle.path, 'evidence')).existsSync(), isFalse);
    },
  );

  linuxTest(
    'fixture CLI rejects an unmarked root without changing it',
    () async {
      final root = Directory.systemTemp.createTempSync('archway installer ');
      addTearDown(() => root.deleteSync(recursive: true));
      final sentinel = File(p.join(root.path, 'sentinel'))
        ..writeAsStringSync('keep');
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/ci/linux_installer_fixture.dart',
        root.path,
        'a' * 64,
        'cleanup',
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Invalid owned installer root'));
      expect(sentinel.readAsStringSync(), 'keep');
    },
  );
}

Directory makeBundle(Directory base) {
  final bundle = Directory(p.join(base.path, 'bundle'))..createSync();
  final names = <String>{
    'bin/linux-x64/archway',
    'native/linux-x64/libarchway_io.so',
    'LICENSE',
    'README.txt',
    'schemas/policy.schema.json',
    'schemas/public-result.schema.json',
    'schemas/export-diagnostics.schema.json',
    for (final name in [
      'typescript/package.json',
      'typescript/lib/typescript.js',
      'typescript/LICENSE.txt',
      'yaml/package.json',
      'yaml/dist/index.js',
      'yaml/LICENSE',
    ])
      'assets/typescript/vendor/$name',
  };
  for (final entity in Directory('assets/typescript').listSync()) {
    if (entity is File &&
        ['.cjs', '.json', '.md'].contains(p.extension(entity.path))) {
      names.add('assets/typescript/${p.basename(entity.path)}');
    }
  }
  for (final entity in Directory('assets/typescript/licenses').listSync()) {
    if (entity is File && p.extension(entity.path) == '.txt')
      names.add('assets/typescript/licenses/${p.basename(entity.path)}');
  }
  final files = <String, Object?>{};
  for (final name in names) {
    final bytes = utf8.encode('synthetic $name\n');
    final file = File(p.join(bundle.path, name))
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    final mode = name.startsWith('bin/') ? 493 : 420;
    posix.chmod(file.path, mode.toRadixString(8));
    files[name] = {
      'mode': mode,
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }
  File(p.join(bundle.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'schema_version': 1,
      'target': 'linux-x64',
      'source': {'commit': 'a' * 40},
      'version': '0.1.0',
      'files': files,
    }),
  );
  return bundle;
}

File makeWrapper(Directory base) => File(p.join(base.path, 'fake_dpkg.dart'))
  ..writeAsStringSync(
    r'''// Synthetic fake: never invokes dpkg or uses privileges.
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.first != 'dpkg') {
    final result = await Process.run(args.first, args.sublist(1));
    stdout.write(result.stdout); stderr.write(result.stderr); exitCode = result.exitCode; return;
  }
  if (!args[1].startsWith('--root=') || !args[2].startsWith('--log=') || args[3] != '--force-script-chrootless') throw StateError('Unsafe dpkg arguments');
  final root = args[1].substring(7);
  final manifest = File('$root/usr/lib/archway/manifest.json');
  if (manifest.existsSync()) {
    final files = (jsonDecode(manifest.readAsStringSync()) as Map)['files'] as Map;
    for (final name in files.keys) File('$root/usr/lib/archway/$name').deleteSync();
    manifest.deleteSync(); Link('$root/usr/bin/archway').deleteSync();
  }
  if (args[4] == '--install') {
    final result = await Process.run('dpkg-deb', ['--extract', args[5], root]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  } else if (args[4] != '--remove') { throw StateError('Unknown fake command'); }
  File(args[2].substring(6)).writeAsStringSync('${args[4]}\n', mode: FileMode.append);
}
''',
  );
