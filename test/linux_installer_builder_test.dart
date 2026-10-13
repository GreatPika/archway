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
    expect(
      preinst.readAsStringSync(),
      File('tool/installers/linux/preinst').readAsStringSync() +
          '\n' +
          expectedPreflight +
          names.map((name) => '/usr/lib/archway/$name\n').join() +
          'ARCHWAY_FILES\n',
    );
    // Python appends a leading newline after the template's final newline.
    expect(
      preinst.readAsStringSync(),
      contains('configuration.\n\nwhile IFS= read -r path; do\n'),
    );
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
    final foreign = File(p.join(system.path, 'usr/lib/archway/README.txt'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('unrelated');
    final refused = await Process.run('sh', [
      preinst.path,
      'upgrade',
    ], environment: environment);
    expect(refused.exitCode, 1);
    expect(refused.stderr, contains('Archway conflict:'));
    expect(foreign.readAsStringSync(), 'unrelated');
    expect(File(p.join(system.path, 'usr/bin/archway')).existsSync(), isFalse);
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

// Literal appended lifecycle text from the original Python builder.
const expectedPreflight = r'''
while IFS= read -r path; do
    if exists "$root$path"; then
        [ ! -L "$root$path" ] && [ -f "$root$path" ] || conflict "$path is not an ordinary file"
        owned "$path" || conflict "$path is not owned by this package"
    fi
    parent=${path%/*}
    while [ "$parent" != /usr/lib ]; do
        if exists "$root$parent"; then
            [ ! -L "$root$parent" ] && [ -d "$root$parent" ] || conflict "$parent is not an ordinary directory"
        fi
        parent=${parent%/*}
    done
done <<'ARCHWAY_FILES'
''';
