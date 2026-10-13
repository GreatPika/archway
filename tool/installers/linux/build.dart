// Build an unsigned .deb from an extracted, verified native release bundle.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import '../../release/installation_artifact.dart';
import '../../release/native_manifest.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      if (i + 1 == arguments.length ||
          ![
            '--bundle',
            '--expected-commit',
            '--output',
          ].contains(arguments[i]) ||
          options.containsKey(arguments[i])) {
        throw const FormatException(
          'Expected --bundle, --expected-commit and --output',
        );
      }
      options[arguments[i]] = arguments[i + 1];
    }
    if (options.length != 3) {
      throw const FormatException(
        'Expected --bundle, --expected-commit and --output',
      );
    }
    await build(
      Directory(options['--bundle']!),
      options['--expected-commit']!,
      File(options['--output']!),
    );
  } catch (error) {
    stderr.writeln('Archway package build failed: $error');
    exitCode = 1;
  }
}

Future<void> build(Directory bundle, String expectedCommit, File output) async {
  bundle = bundle.absolute;
  output = output.absolute;
  if (await bundle.resolveSymbolicLinks() != bundle.path ||
      await FileSystemEntity.type(bundle.path, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw const FormatException(
      'Bundle must be an ordinary canonical directory',
    );
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException(
      'Output must be fresh and outside the input bundle',
    );
  }
  output = File(await _resolveMissing(output.path));
  if (p.isWithin(bundle.path, output.path)) {
    throw const FormatException(
      'Output must be fresh and outside the input bundle',
    );
  }
  final parsed = await readNativeManifest(
    File(p.join(bundle.path, 'manifest.json')),
  );
  final manifest = parsed.manifest;
  final source = manifest['source'];
  final version = manifest['version'];
  if (manifest['schema_version'] != 1 ||
      manifest['target'] != 'linux-x64' ||
      source is! Map ||
      source['commit'] != expectedCommit ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(expectedCommit) ||
      version is! String ||
      !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) {
    throw const FormatException('Wrong release target, source or version');
  }
  final required = <String>{
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
  final here = File.fromUri(Platform.script).parent;
  final assets = Directory(
    p.join(here.parent.parent.parent.path, 'assets/typescript'),
  );
  for (final entry in await assets.list().toList()) {
    if (['.cjs', '.json', '.md'].contains(p.extension(entry.path))) {
      required.add('assets/typescript/${p.basename(entry.path)}');
    }
  }
  await for (final entry in Directory(p.join(assets.path, 'licenses')).list()) {
    if (p.extension(entry.path) == '.txt') {
      required.add('assets/typescript/licenses/${p.basename(entry.path)}');
    }
  }
  final inventory = parsed.completeArchiveInventory;
  if (!inventory.files.keys.toSet().containsAll(required)) {
    throw const FormatException('Incomplete release bundle');
  }
  if (inventory.files['bin/linux-x64/archway']!.mode != 0x1ed) {
    throw const FormatException('Invalid executable mode');
  }
  await verifyInstallationDirectory(bundle, inventory, compareModes: true);
  await output.parent.create(recursive: true);
  final temp = await output.parent.createTemp('.archway-deb-');
  try {
    posix.chmod(temp.path, '700');
    final stage = Directory(p.join(temp.path, 'package'));
    final payload = Directory(p.join(stage.path, 'usr/lib/archway'));
    // The shared verifier has already established the complete ordinary tree.
    final directories = <String>{'.'};
    for (final entry in inventory.files.entries) {
      final parts = entry.key.split('/');
      for (var i = 1; i < parts.length; i++) {
        directories.add(parts.take(i).join('/'));
      }
      final destination = File(p.join(payload.path, entry.key));
      await destination.parent.create(recursive: true);
      final source = File(p.join(bundle.path, entry.key));
      await source.copy(destination.path);
      posix.chmod(
        destination.path,
        ((await source.stat()).mode & 0xfff).toRadixString(8),
      );
    }
    for (final name
        in directories.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      final mode =
          (await Directory(p.join(bundle.path, name)).stat()).mode & 0xfff;
      posix.chmod(p.join(payload.path, name), mode.toRadixString(8));
    }
    await verifyInstallationDirectory(payload, inventory, compareModes: true);
    final command = Link(p.join(stage.path, 'usr/bin/archway'));
    await command.parent.create(recursive: true);
    await command.create('/usr/lib/archway/bin/linux-x64/archway');
    final control = Directory(p.join(stage.path, 'DEBIAN'));
    await control.create();
    await File(p.join(control.path, 'control')).writeAsString(
      'Package: archway\nVersion: $version\n'
      'Architecture: amd64\nMaintainer: Archway maintainers\n'
      'Section: devel\nPriority: optional\n'
      'Description: Architecture checks for prepared TypeScript and Dart projects\n'
      ' Unsigned preview. Analysis runtimes are separate prerequisites.\n',
    );
    final preinst = File(p.join(control.path, 'preinst'));
    await preinst.writeAsString(
      await File(p.join(here.path, 'preinst')).readAsString() +
          '\n' +
          _preflight +
          (inventory.files.keys.toList()..sort())
              .map((name) => '/usr/lib/archway/$name\n')
              .join() +
          'ARCHWAY_FILES\n',
    );
    posix.chmod(preinst.path, '755');
    final artifact = File(p.join(temp.path, 'archway.deb'));
    await _dpkg(['--root-owner-group', '--build', stage.path, artifact.path]);
    final readback = Directory(p.join(temp.path, 'readback'));
    await _dpkg(['--extract', artifact.path, readback.path]);
    await verifyInstallationDirectory(
      Directory(p.join(readback.path, 'usr/lib/archway')),
      inventory,
      compareModes: true,
    );
    if (await Link(p.join(readback.path, 'usr/bin/archway')).target() !=
        '/usr/lib/archway/bin/linux-x64/archway') {
      throw const FormatException('Packaged command differs from stage');
    }
    // Hard-link publication is atomic and refuses any concurrent destination.
    posix.link(artifact.path, output.path);
  } finally {
    await temp.delete(recursive: true);
  }
  stdout.writeln(
    '${await sha256.bind(output.openRead()).first}  ${p.basename(output.path)}',
  );
}

// Resolve existing ancestors before creating any output directories, including
// an alias followed by as-yet nonexistent components (Path.resolve semantics).
Future<String> _resolveMissing(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return File(path).resolveSymbolicLinks();
  }
  final parent = p.dirname(path);
  if (parent == path) return path;
  return p.join(await _resolveMissing(parent), p.basename(path));
}

Future<void> _dpkg(List<String> arguments) async {
  final result = await Process.run('dpkg-deb', arguments);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(
      'dpkg-deb',
      arguments,
      'Package command failed',
      result.exitCode,
    );
  }
}

const _preflight = r'''
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
