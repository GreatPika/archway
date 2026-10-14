// Actual archive packaging only; this does not establish installed lifecycle acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

const commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  void linuxTest(String name, dynamic Function() body) => test(
    name,
    body,
    skip: Platform.isLinux ? false : 'Requires Linux dpkg archive packaging.',
  );
  late Directory base, bundle;
  late File output;
  late Map<String, dynamic> manifest;
  void save() =>
      File(p.join(bundle.path, 'manifest.json'))
          .writeAsStringSync(jsonEncode(manifest));
  Future<ProcessResult> build({Map<String, String>? environment}) =>
      Process.run(Platform.resolvedExecutable, [
        'tool/installers/linux/build.dart',
        '--bundle',
        bundle.path,
        '--expected-commit',
        commit,
        '--output',
        output.path,
      ], environment: environment);
  setUp(() {
    base = Directory(
      Directory.systemTemp
          .createTempSync('deb café-')
          .resolveSymbolicLinksSync(),
    );
    bundle = Directory(p.join(base.path, 'bundle'))..createSync();
    output = File(p.join(base.path, 'archway.deb'));
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
      if (entity is File && p.extension(entity.path) == '.txt') {
        names.add('assets/typescript/licenses/${p.basename(entity.path)}');
      }
    }
    final files = <String, dynamic>{};
    for (final name in names) {
      final bytes = utf8.encode('synthetic $name\n');
      final file = File(p.join(bundle.path, name))
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      final mode = name == 'bin/linux-x64/archway' ? 493 : 420;
      posix.chmod(file.path, mode.toRadixString(8));
      files[name] = {
        'mode': mode,
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      };
    }
    manifest = {
      'schema_version': 1,
      'target': 'linux-x64',
      'source': {'commit': commit},
      'version': '0.1.0',
      'files': files,
    };
    save();
  });
  tearDown(() => base.deleteSync(recursive: true));
  linuxTest('packages exact payload, modes, metadata and launcher', () async {
    posix.chmod(p.join(bundle.path, 'assets'), '711');
    final result = await build();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final extracted = p.join(base.path, 'extracted');
    expect(
      (await Process.run('dpkg-deb', ['-x', output.path, extracted])).exitCode,
      0,
    );
    expect(
      Directory(p.join(extracted, 'usr/lib/archway/assets')).statSync().mode &
          0xfff,
      0x1c9,
    );
    for (final source in bundle.listSync(recursive: true).whereType<File>()) {
      final copy = File(
        p.join(
          extracted,
          'usr/lib/archway',
          p.relative(source.path, from: bundle.path),
        ),
      );
      expect(copy.readAsBytesSync(), source.readAsBytesSync());
      expect(copy.statSync().mode & 0xfff, source.statSync().mode & 0xfff);
    }
    expect(
      Link(p.join(extracted, 'usr/bin/archway')).targetSync(),
      '/usr/lib/archway/bin/linux-x64/archway',
    );
    final metadata = await Process.run('dpkg-deb', [
      '-f',
      output.path,
      'Package',
      'Version',
      'Architecture',
    ]);
    expect(
      metadata.stdout,
      'Package: archway\nVersion: 0.1.0\nArchitecture: amd64\n',
    );
    final control = p.join(base.path, 'control');
    expect(
      (await Process.run('dpkg-deb', ['-e', output.path, control])).exitCode,
      0,
    );
    final preinst = File(p.join(control, 'preinst'));
    final names = [
      ...(manifest['files'] as Map).keys.cast<String>(),
      'manifest.json',
    ]..sort();
    expect(preinst.statSync().mode & 0xfff, 493);
    // Run only the read-only preflight against a temporary synthetic root.
    final system = Directory(p.join(base.path, 'system'))..createSync();
    final environment = {
      'DPKG_ROOT': system.path,
      'DPKG_ADMINDIR': p.join(system.path, 'db'),
    };
    final clean = await Process.run('sh', [
      preinst.path,
      'install',
    ], environment: environment);
    expect(clean.exitCode, 0, reason: clean.stderr.toString());
    final foreign = File(p.join(system.path, 'usr/lib/archway/unrelated.txt'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('unrelated');
    final refused = await Process.run('sh', [
      preinst.path,
      'upgrade',
    ], environment: environment);
    expect(refused.exitCode, 1);
    expect(
      refused.stderr,
      'Archway conflict: /usr/lib/archway is not owned by this package\n',
    );
    expect(foreign.readAsStringSync(), 'unrelated');
    expect(File(p.join(system.path, 'usr/bin/archway')).existsSync(), isFalse);
    foreign.deleteSync();
    // Real dpkg-query reads only this disposable ownership database. Owning the
    // root lets the generated incoming-file and ancestor checks run themselves.
    final database = Directory(environment['DPKG_ADMINDIR']!)
      ..createSync(recursive: true);
    File(p.join(database.path, 'status')).writeAsStringSync(
      'Package: archway\nStatus: install ok installed\n'
      'Architecture: amd64\nVersion: 0.1.0\n'
      'Maintainer: Archway fixture <fixture@example.invalid>\n'
      'Description: Temporary preflight ownership fixture\n\n',
    );
    final ownership = File(p.join(database.path, 'info/archway.list'))
      ..parent.createSync();
    Future<ProcessResult> preflight() =>
        Process.run('sh', [preinst.path, 'upgrade'], environment: environment);
    for (final name in names) {
      final ownedPath = '/usr/lib/archway/$name';
      ownership.writeAsStringSync('/usr/lib/archway\n');
      final candidate = File(p.join(system.path, 'usr/lib/archway', name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('unowned incoming collision');
      final refused = await preflight();
      expect(refused.exitCode, 1, reason: name);
      expect(
        refused.stderr,
        'Archway conflict: $ownedPath is not owned by this package\n',
        reason: name,
      );
      expect(candidate.readAsStringSync(), 'unowned incoming collision');
      ownership.writeAsStringSync('/usr/lib/archway\n$ownedPath\n');
      final accepted = await preflight();
      expect(accepted.exitCode, 0, reason: '$name: ${accepted.stderr}');
      expect(candidate.readAsStringSync(), 'unowned incoming collision');
      candidate.deleteSync();
    }
    ownership.writeAsStringSync('/usr/lib/archway\n/usr/lib/archway/LICENSE\n');
    final leafPath = p.join(system.path, 'usr/lib/archway/LICENSE');
    final outside = File(p.join(base.path, 'foreign-preflight-target'))
      ..writeAsStringSync('foreign target');
    for (final linked in [false, true]) {
      if (linked) {
        Link(leafPath).createSync(outside.path);
      } else {
        Directory(leafPath).createSync();
      }
      final refused = await preflight();
      expect(refused.exitCode, 1);
      expect(
        refused.stderr,
        'Archway conflict: /usr/lib/archway/LICENSE is not an ordinary file\n',
      );
      expect(outside.readAsStringSync(), 'foreign target');
      if (linked) {
        expect(Link(leafPath).targetSync(), outside.path);
        Link(leafPath).deleteSync();
      } else {
        expect(Directory(leafPath).listSync(), isEmpty);
        Directory(leafPath).deleteSync();
      }
    }
    final parentPath = p.join(system.path, 'usr/lib/archway/assets');
    Directory(parentPath).deleteSync(recursive: true);
    final outsideDirectory = Directory(
      p.join(base.path, 'foreign-preflight-directory'),
    )..createSync();
    for (final linked in [false, true]) {
      if (linked) {
        Link(parentPath).createSync(outsideDirectory.path);
      } else {
        File(parentPath).writeAsStringSync('foreign parent');
      }
      final refused = await preflight();
      expect(refused.exitCode, 1);
      expect(
        refused.stderr,
        'Archway conflict: /usr/lib/archway/assets is not an ordinary directory\n',
      );
      expect(outsideDirectory.listSync(), isEmpty);
      if (linked) {
        expect(Link(parentPath).targetSync(), outsideDirectory.path);
        Link(parentPath).deleteSync();
      } else {
        expect(File(parentPath).readAsStringSync(), 'foreign parent');
        File(parentPath).deleteSync();
      }
    }
    expect(
      result.stdout.toString(),
      contains('${sha256.convert(output.readAsBytesSync())}  archway.deb'),
    );
    expect(
      base.listSync().where(
        (e) => p.basename(e.path).startsWith('.archway-deb-'),
      ),
      isEmpty,
    );
  });
  for (final mutation in [
    'target',
    'commit',
    'version',
    'schema',
    'helper',
    'bytes',
    'mode',
    'extra',
    'link',
    'inventory path',
    'oversize',
  ]) {
    linuxTest('rejects $mutation before publication', () async {
      final files = manifest['files'] as Map<String, dynamic>;
      final file = File(p.join(bundle.path, 'assets/typescript/helper.cjs'));
      switch (mutation) {
        case 'target':
          manifest['target'] = 'macos-arm64';
        case 'commit':
          manifest['source'] = {'commit': 'b' * 40};
        case 'version':
          manifest['version'] = '0.1.0-preview';
        case 'schema':
          manifest['schema_version'] = 2;
        case 'helper':
          file.deleteSync();
          files.remove('assets/typescript/helper.cjs');
        case 'bytes':
          file.writeAsStringSync('corrupt');
        case 'mode':
          posix.chmod(file.path, '755');
        case 'extra':
          File(p.join(bundle.path, 'unlisted')).writeAsStringSync('x');
        case 'link':
          final target = file.renameSync(p.join(base.path, 'outside'));
          Link(file.path).createSync(target.path);
        case 'inventory path':
          files['../escape'] = files.values.first;
        case 'oversize':
          files.values.first['size'] = 128 * 1024 * 1024 + 1;
      }
      save();
      final result = await build();
      expect(result.exitCode, 1, reason: result.stderr.toString());
      expect(output.existsSync(), isFalse);
      expect(
        base.listSync().where(
          (e) => p.basename(e.path).startsWith('.archway-deb-'),
        ),
        isEmpty,
      );
    });
  }
  linuxTest('refuses existing output including dangling symlinks', () async {
    output.writeAsStringSync('existing artifact');
    expect((await build()).exitCode, 1);
    expect(output.readAsStringSync(), 'existing artifact');
    output.deleteSync();
    Link(output.path).createSync(p.join(base.path, 'absent'));
    expect((await build()).exitCode, 1);
    expect(Link(output.path).targetSync(), p.join(base.path, 'absent'));
  });
  linuxTest(
    'resolves output parent aliases before making missing directories',
    () async {
      final alias = Link(p.join(base.path, 'alias'))..createSync(bundle.path);
      output = File(p.join(alias.path, 'new/archway.deb'));
      final result = await build();
      expect(result.exitCode, 1);
      expect(result.stderr, contains('outside the input bundle'));
      expect(Directory(p.join(bundle.path, 'new')).existsSync(), isFalse);
    },
  );
  linuxTest('rejects aliased bundle', () async {
    final alias = Link(p.join(base.path, 'alias'))..createSync(bundle.path);
    bundle = Directory(alias.path);
    expect((await build()).exitCode, 1);
    expect(output.existsSync(), isFalse);
  });
  for (final fault in ['command failure', 'payload', 'launcher', 'winner']) {
    linuxTest('cleans staging and refuses $fault', () async {
      final real = (await Process.run('sh', [
        '-c',
        'command -v dpkg-deb',
      ])).stdout.toString().trim();
      final commands = Directory(p.join(base.path, 'commands'))..createSync();
      final wrapper = File(p.join(commands.path, 'dpkg-deb'));
      wrapper.writeAsStringSync(
        '#!/bin/sh\nset -eu\n' +
            (fault == 'command failure'
                ? 'exit 42\n'
                : '\"$real\" \"\$@\"\n' +
                      'if [ \"\$1\" = --extract ]; then\n' +
                      switch (fault) {
                        'payload' => 'printf corrupt > \"\$3/usr/lib/archway/README.txt\"\n',
                        'launcher' => 'rm \"\$3/usr/bin/archway\"; ln -s /foreign \"\$3/usr/bin/archway\"\n',
                        _ => 'printf winner > \"${output.path}\"\n',
                      } +
                      'fi\n'),
      );
      posix.chmod(wrapper.path, '755');
      final result = await build(
        environment: {
          'PATH': '${commands.path}:${Platform.environment['PATH']}',
        },
      );
      expect(result.exitCode, 1, reason: result.stderr.toString());
      if (fault == 'winner') {
        expect(output.readAsStringSync(), 'winner');
      } else {
        expect(output.existsSync(), isFalse);
      }
      expect(
        base.listSync().where(
          (e) => p.basename(e.path).startsWith('.archway-deb-'),
        ),
        isEmpty,
      );
    });
  }
}
