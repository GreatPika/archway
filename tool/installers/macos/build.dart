// Maintainer-only unsigned/unnotarized packaging. Staging is fixture evidence,
// not native installation or downloaded-file acceptance.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import '../../release/installation_artifact.dart';
import '../../release/native_manifest.dart';
import '../../release/publish_directory.dart';

const _required = {
  'bin/macos-arm64/archway',
  'native/macos-arm64/libarchway_io.dylib',
  'LICENSE',
  'README.txt',
  'schemas/policy.schema.json',
  'schemas/public-result.schema.json',
  'schemas/export-diagnostics.schema.json',
  'assets/typescript/licenses/pnpm-MIT.txt',
  'assets/typescript/licenses/yaml-ISC.txt',
};

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

// Resolve existing ancestors before creating anything, including aliased parents.
Future<String> _resolvedOutput(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return File(path).resolveSymbolicLinks();
  }
  return p.join(await _resolvedOutput(p.dirname(path)), p.basename(path));
}

Future<NativeManifest> buildMacInstaller(
  Directory bundle,
  Directory output, {
  required Directory installerDirectory,
  bool stageOnly = false,
}) async {
  if (!stageOnly && (!Platform.isMacOS || Abi.current() != Abi.macosArm64)) {
    throw const FormatException(
      'pkgbuild requires a native macOS arm64 host; use --stage-only for fixtures',
    );
  }
  if (Platform.isWindows)
    throw UnsupportedError('Staging requires POSIX modes');
  bundle = bundle.absolute;
  if (!await bundle.exists() ||
      await bundle.resolveSymbolicLinks() != bundle.path) {
    throw const FormatException(
      'Bundle must be an ordinary canonical directory',
    );
  }
  output = output.absolute;
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException(
      'Output must be fresh and outside the input bundle',
    );
  }
  output = Directory(await _resolvedOutput(output.path));
  if (p.equals(bundle.path, output.path) ||
      p.isWithin(bundle.path, output.path)) {
    throw const FormatException(
      'Output must be fresh and outside the input bundle',
    );
  }
  final parsed = await readNativeManifest(
    File(p.join(bundle.path, 'manifest.json')),
  );
  final manifest = parsed.manifest;
  final inventory = parsed.completeArchiveInventory;
  if (manifest['target'] != 'macos-arm64' || manifest['schema_version'] != 1) {
    throw const FormatException('Expected macos-arm64 release bundle');
  }
  if (manifest['version'] is! String ||
      !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$')
          .hasMatch(manifest['version'] as String)) {
    throw const FormatException('Expected numeric package version');
  }
  if (!_required.every(inventory.files.containsKey)) {
    throw const FormatException('Incomplete release bundle');
  }
  for (final entry in inventory.files.entries) {
    if (!RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(entry.key)) {
      throw const FormatException('Unsafe bundle path');
    }
    if (entry.key.startsWith('.') ||
        entry.key == 'uninstall.sh' ||
        entry.key.startsWith('uninstall.sh/')) {
      throw const FormatException('Reserved installer metadata path');
    }
    if (entry.value.mode != 0x1a4 && entry.value.mode != 0x1ed) {
      throw const FormatException('Unexpected payload permissions');
    }
  }
  if (inventory.files['bin/macos-arm64/archway']!.mode != 0x1ed) {
    throw const FormatException(
      'Native executable must retain executable permissions',
    );
  }
  // Shared producer inventory pins manifest.json to 0644, including for staging.
  await verifyInstallationDirectory(bundle, inventory, compareModes: true);
  await output.parent.create(recursive: true);
  final stage = await output.parent.createTemp('.archway-macos-');
  var published = false;
  try {
    posix.chmod(stage.path, '700');
    final payload = Directory(p.join(stage.path, 'root/usr/local/lib/archway'));
    final preparedDirectories = <String>{stage.path};
    for (final entry in inventory.files.entries) {
      final copy = File(p.join(payload.path, entry.key));
      await copy.parent.create(recursive: true);
      // pkgbuild retains directory modes: ambient umask must not make installed
      // /usr/local parents private. The outer temporary stage stays 0700.
      var directory = copy.parent;
      while (preparedDirectories.add(directory.path)) {
        posix.chmod(directory.path, '755');
        directory = directory.parent;
      }
      await File(p.join(bundle.path, entry.key)).copy(copy.path);
      posix.chmod(copy.path, entry.value.mode.toRadixString(8));
    }
    await verifyInstallationDirectory(payload, inventory, compareModes: true);
    final scripts = Directory(p.join(stage.path, 'scripts'));
    await scripts.create();
    posix.chmod(scripts.path, '755');
    final common = await File(p.join(installerDirectory.path, 'lifecycle.sh'))
        .readAsString();
    for (final name in ['preinstall', 'postinstall', 'uninstall']) {
      final script = File(
        name == 'uninstall'
            ? p.join(payload.path, 'uninstall.sh')
            : p.join(scripts.path, name),
      );
      await script.writeAsString('$common\n$name "\$@"\n');
      posix.chmod(script.path, '755');
    }
    final names = [...inventory.files.keys, 'uninstall.sh']..sort();
    final owned = StringBuffer();
    for (final name in names) {
      final file = File(p.join(payload.path, name));
      owned.writeln(
        '${await _digest(file)} ${((await file.stat()).mode & 0xfff).toRadixString(8)} $name',
      );
    }
    final ownership = File(p.join(scripts.path, 'owned.sha256'));
    await ownership.writeAsString('$owned');
    posix.chmod(ownership.path, '644');
    if (!stageOnly) {
      await packageMacInstaller(stage, parsed, installerDirectory, Process.run);
    }
    publishDirectory(stage, output);
    published = true;
    return parsed;
  } finally {
    if (!published) await stage.delete(recursive: true);
  }
}

/// Private command fixture seam. Calling this directly proves orchestration only;
/// the CLI/build entrypoint retains the actual native host gate.
Future<void> packageMacInstaller(
  Directory stage,
  NativeManifest parsed,
  Directory installerDirectory,
  Future<ProcessResult> Function(String, List<String>) run,
) async {
  final version = parsed.manifest['version'] as String;
  final package = File(
    p.join(stage.path, 'archway-$version-macos-arm64-unsigned.pkg'),
  );
  final result = await run('/usr/bin/pkgbuild', [
    '--root',
    p.join(stage.path, 'root'),
    '--scripts',
    p.join(stage.path, 'scripts'),
    '--identifier',
    'org.archway.cli',
    '--version',
    version,
    '--install-location',
    '/',
    '--ownership',
    'recommended',
    package.path,
  ]);
  if (result.exitCode != 0)
    throw ProcessException(
      '/usr/bin/pkgbuild',
      [],
      '${result.stderr}',
      result.exitCode,
    );
  final inputs = <String, String>{};
  for (final name in ['build.dart', 'lifecycle.sh']) {
    inputs[name] = await _digest(File(p.join(installerDirectory.path, name)));
  }
  await File(p.join(stage.path, 'installer-evidence.json')).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({
      'source': parsed.manifest['source'],
      'target': 'macos-arm64',
      'host': {'system': Platform.isMacOS ? 'Darwin' : Platform.operatingSystem, 'machine': Abi.current() == Abi.macosArm64 ? 'arm64' : Abi.current().toString(), 'release': Platform.operatingSystemVersion},
      'route': 'unsigned-unnotarized-pkg-build',
      'sha256': await _digest(package),
      'filename': p.basename(package.path),
      'bundle_manifest_sha256': parsed.manifestSha256,
      'installer_inputs_sha256': inputs,
      'scope': 'Build only; not lifecycle, fresh-terminal or downloaded-file GUI acceptance',
    })}\n',
  );
}

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    var stageOnly = false;
    for (var i = 0; i < arguments.length; i++) {
      final name = arguments[i];
      if (name == '--stage-only' && !stageOnly) {
        stageOnly = true;
      } else if ((name == '--bundle' || name == '--output') &&
          !options.containsKey(name) &&
          i + 1 < arguments.length) {
        options[name] = arguments[++i];
      } else {
        throw const FormatException(
          'Expected --bundle PATH --output PATH [--stage-only]',
        );
      }
    }
    if (options.length != 2)
      throw const FormatException(
        'Expected --bundle PATH --output PATH [--stage-only]',
      );
    final parsed = await buildMacInstaller(
      Directory(options['--bundle']!),
      Directory(options['--output']!),
      installerDirectory: File.fromUri(Platform.script).parent,
      stageOnly: stageOnly,
    );
    if (!stageOnly) {
      final package = File(
        p.join(
          options['--output']!,
          'archway-${parsed.manifest['version']}-macos-arm64-unsigned.pkg',
        ),
      );
      stdout.writeln(
        '${await _digest(package)}  ${await package.resolveSymbolicLinks()}',
      );
    }
    stdout.writeln(
      'Staged unsigned/unnotarized installer; no publication or route certification.',
    );
  } catch (error) {
    stderr.writeln('macOS installer failed: $error');
    exitCode = 1;
  }
}
