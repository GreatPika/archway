// npm owns installation and its generated shims; this probe never rebuilds a package.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ci/installed_command_recorder.dart';
import '../../test/support/windows_command.dart';
import 'windows_shim_command.dart';

const npmProductName = 'archway-architecture-cli';

final class NpmInstalledRoute {
  NpmInstalledRoute({
    required this.route,
    required this.archive,
    required this.node,
    required this.npmCli,
    required this.project,
    required this.installation,
    required this.environment,
    required this.recorder,
  }) {
    if (!['local', 'global', 'cache'].contains(route)) {
      throw ArgumentError.value(route, 'route');
    }
    for (final file in [archive, node, npmCli]) {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          file.resolveSymbolicLinksSync() != file.path) {
        throw StateError('npm route input must be a canonical ordinary file');
      }
    }
    if (project.resolveSymbolicLinksSync() != project.path ||
        !p.isAbsolute(installation.path) ||
        p.normalize(installation.path) != installation.path) {
      throw StateError('npm route directories must be canonical');
    }
    if (route == 'local' && installation.path != project.path) {
      throw StateError('Local npm installation must be the inspected project');
    }
  }

  final String route;
  final File archive, node, npmCli;
  final Directory project;
  Directory installation;
  final Map<String, String> environment;
  final InstalledCommandRecorder recorder;
  File? _cachedShim;
  Directory? _cachedPackage;
  Map<String, dynamic>? cacheSelection;

  Future<void> install() async {
    if (Platform.isWindows) {
      environment.removeWhere((key, _) => key.toUpperCase() == 'COMSPEC');
      environment['COMSPEC'] = systemCmd;
    }
    if (route == 'cache') {
      await _locateCache();
      return;
    }
    await recorder.capture(
      [
        node.path,
        npmCli.path,
        'install',
        if (route == 'local') '-D' else '--global',
        '--prefix',
        installation.path,
        archive.path,
        '--offline',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
      ],
      workingDirectory: project.path,
      environment: environment,
      timeout: const Duration(seconds: 120),
    );
    if (route == 'local') {
      final metadata = jsonDecode(
        File(p.join(project.path, 'package.json')).readAsStringSync(),
      );
      if (metadata['devDependencies'] is! Map ||
          !(metadata['devDependencies'] as Map).containsKey(npmProductName)) {
        throw StateError('Local npm route must be a devDependency');
      }
    }
    if (!shim.existsSync()) throw StateError('npm-generated shim is missing');
  }

  File get shim =>
      _cachedShim ??
      File(
        route == 'global'
            ? p.join(
                installation.path,
                Platform.isWindows ? 'archway.cmd' : 'bin/archway',
              )
            : p.join(
                installation.path,
                'node_modules/.bin',
                Platform.isWindows ? 'archway.cmd' : 'archway',
              ),
      );

  Directory get packageRoot =>
      _cachedPackage ??
      Directory(
        p.join(
          installation.path,
          route == 'global' && !Platform.isWindows
              ? 'lib/node_modules'
              : 'node_modules',
          npmProductName,
        ),
      );

  Future<void> _locateCache() async {
    final cacheValue = environment['npm_config_cache'];
    if (cacheValue == null || !p.isAbsolute(cacheValue)) {
      throw StateError('npm exec requires an explicit isolated cache');
    }
    final boundary = p.join(cacheValue, '_npx');
    if (Directory(boundary).existsSync()) {
      throw StateError('npm exec cache selection must start empty');
    }
    environment['npm_config_script_shell'] = Platform.isWindows
        ? systemCmd
        : '/bin/sh';
    final locator = File(
      p.join(recorder.output.parent.path, 'npm cache locator.cjs'),
    );
    locator.createSync(exclusive: true);
    try {
      locator.writeAsStringSync(r"""
const fs = require('node:fs'), path = require('node:path');
function find(name) {
  const suffixes = process.platform === 'win32' ? (process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').map(s => s.toLowerCase()) : [''];
  for (const directory of process.env.PATH.split(path.delimiter)) for (const suffix of suffixes) {
    const file = path.join(directory, name + suffix);
    try { if (fs.statSync(file).isFile()) { fs.accessSync(file, fs.constants.X_OK); return file; } } catch (_) {}
  }
  return null;
}
const shim = find('archway');
if (!shim) throw Error('npm exec did not select an Archway shim');
const installed = fs.realpathSync(path.join(path.dirname(path.dirname(shim)), 'archway-architecture-cli'));
console.log(JSON.stringify({shim,installed,node:process.execPath,version:process.version,dart:find('dart')}));
""");
      final result = await recorder.capture(
        [
          node.path,
          npmCli.path,
          'exec',
          '--offline',
          '--ignore-scripts',
          '--yes',
          '--package=${archive.path}',
          '--',
          'node',
          locator.path,
        ],
        workingDirectory: project.path,
        environment: environment,
        timeout: const Duration(seconds: 120),
      );
      if (result.stderr.isNotEmpty)
        throw StateError('Unexpected npm cache locator stderr');
      final value = jsonDecode(utf8.decode(result.stdout));
      if (value is! Map<String, dynamic> ||
          value['shim'] is! String ||
          value['installed'] is! String ||
          value['node'] is! String) {
        throw StateError('Invalid npm cache selection');
      }
      final shim = File(value['shim'] as String);
      final installed = Directory(value['installed'] as String);
      if (!p.isWithin(boundary, shim.path) ||
          !p.isWithin(boundary, shim.resolveSymbolicLinksSync()) ||
          !p.isWithin(boundary, installed.path) ||
          installed.resolveSymbolicLinksSync() != installed.path ||
          p.basename(shim.parent.path) != '.bin' ||
          p.basename(shim.path) !=
              (Platform.isWindows ? 'archway.cmd' : 'archway') ||
          Directory(p.join(shim.parent.parent.path, npmProductName))
                  .resolveSymbolicLinksSync() !=
              installed.path ||
          File(value['node'] as String).resolveSymbolicLinksSync() !=
              node.path ||
          value['version'] != 'v24.21.0' ||
          value['dart'] != null) {
        throw StateError(
          'npm exec selection escaped the isolated cache or runtime',
        );
      }
      _cachedShim = shim;
      _cachedPackage = installed;
      cacheSelection = value;
    } finally {
      locator.deleteSync();
    }
  }

  /// The cache route always invokes npm itself with the one admitted local archive.
  List<String> invocation(List<String> arguments) => route == 'cache'
      ? [
          node.path,
          npmCli.path,
          'exec',
          '--offline',
          '--yes',
          '--package=${archive.path}',
          '--',
          'archway',
          ...arguments,
        ]
      : [shim.path, ...arguments];

  String get systemCmd {
    final root = Platform.environment.entries
        .where((entry) => entry.key.toUpperCase() == 'SYSTEMROOT')
        .map((entry) => entry.value)
        .firstOrNull;
    if (root == null || !p.windows.isAbsolute(root))
      throw StateError('Absolute SystemRoot is required');
    final file = File(p.join(root, 'System32/cmd.exe'));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.resolveSymbolicLinksSync() != file.path)
      throw StateError('System cmd must be canonical and ordinary');
    return file.path;
  }

  WindowsRawCommandLine? windowsCommandFor(List<String> arguments) {
    if (arguments.isEmpty)
      throw ArgumentError('Expected nonempty npm invocation');
    if (!needsCommandShell || arguments.first != shim.path) return null;
    final stat = shim.statSync();
    if (FileSystemEntity.typeSync(shim.path, followLinks: false) !=
            FileSystemEntityType.file ||
        shim.resolveSymbolicLinksSync() != shim.path ||
        stat.size > 8191)
      throw StateError('Unexpected npm shim input');
    return windowsNpmShimCommand(
      arguments,
      cmdExecutable: systemCmd,
      nodeExecutable: node.path,
      shimSource: shim.readAsStringSync(),
      environment: environment,
    );
  }

  bool get needsCommandShell => Platform.isWindows && route != 'cache';

  void relocate(Directory destination) {
    if (route == 'cache') throw StateError('npm owns its cache installation');
    if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('npm relocation destination already exists');
    }
    installation = installation.renameSync(destination.path);
  }
}
