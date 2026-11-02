// Maintainer-only genuine SDK install/update/reinstall/uninstall acceptance.
// Run from a clean committed release tree: dart run tool/installation_lifecycle.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../test/support/native_process_support.dart';
import 'installed_package_smoke.dart' as installed;

const predecessorVersion = '0.0.0-test';

// The owned Windows process helper intentionally never searches PATH.
String findGitExecutable(Map<String, String> environment) {
  final path = environment.entries
      .where((entry) => entry.key.toUpperCase() == 'PATH')
      .map((entry) => entry.value)
      .firstOrNull;
  for (final directory in (path ?? '').split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    final file = File(
      p.join(directory, Platform.isWindows ? 'git.exe' : 'git'),
    );
    if (file.existsSync()) return file.resolveSymbolicLinksSync();
  }
  throw StateError('Git executable is not available on the preparation PATH');
}

String replaceVersionMarker(String text, RegExp marker, String replacement) {
  if (marker.allMatches(text).length != 1) {
    throw StateError('Expected exactly one release version marker');
  }
  return text.replaceFirst(marker, replacement);
}

void verifyVersionOutput(NativeProcessResult result, String expected) {
  if (result.exitCode != 0 ||
      result.stderr.isNotEmpty ||
      utf8.decode(result.stdout).replaceAll('\r\n', '\n') !=
          'archway $expected\n') {
    throw StateError('Installed version mismatch: expected $expected; $result');
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--probe') {
    final command = [args[1], '--version'];
    verifyVersionOutput(
      await runNativeProcess(
        command,
        timeout: const Duration(seconds: 45),
        windowsCommand: Platform.isWindows
            ? installed.sdkWindowsBatchCommand(
                command,
                p.join(
                  Platform.environment['SystemRoot']!,
                  'System32',
                  'cmd.exe',
                ),
              )
            : null,
      ),
      args[2],
    );
    await installed.probe([args[1]]);
    return;
  }
  if (args.isNotEmpty) throw ArgumentError('No arguments expected');
  final source = File.fromUri(Platform.script).parent.parent
      .resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.createTempSync('archway-lifecycle-');
  final base = Directory(temporary.resolveSymbolicLinksSync());
  final fixture = Directory(p.join(base.path, 'source'));
  final home = Directory(p.join(base.path, 'home'))..createSync();
  final cache = Directory(p.join(base.path, 'pub-cache'))..createSync();
  final environment = <String, String>{
    for (final entry in Platform.environment.entries)
      if (!{
        'HOME',
        'USERPROFILE',
        'PUB_CACHE',
        'XDG_CACHE_HOME',
        'XDG_CONFIG_HOME',
        'XDG_DATA_HOME',
        'XDG_STATE_HOME',
        'APPDATA',
        'LOCALAPPDATA',
        'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM',
        'GIT_CONFIG_COUNT',
        'GIT_DIR',
        'GIT_WORK_TREE',
        'GIT_INDEX_FILE',
        'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES',
      }.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
    'HOME': home.path,
    'USERPROFILE': home.path,
    'PUB_CACHE': cache.path,
    'XDG_CACHE_HOME': p.join(home.path, '.cache'),
    'XDG_CONFIG_HOME': p.join(home.path, '.config'),
    'XDG_DATA_HOME': p.join(home.path, '.local', 'share'),
    'XDG_STATE_HOME': p.join(home.path, '.local', 'state'),
    'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
    'LOCALAPPDATA': p.join(home.path, 'AppData', 'Local'),
    'GIT_CONFIG_GLOBAL': p.join(home.path, 'empty-gitconfig'),
    'GIT_CONFIG_NOSYSTEM': '1',
    'DASH__SUPPRESS_ANALYTICS': 'true',
  };
  Future<String> run(
    List<String> command, {
    String? cwd,
    Map<String, String>? env,
  }) async {
    final result = await runNativeProcess(
      command,
      timeout: const Duration(minutes: 8),
      workingDirectory: cwd ?? base.path,
      environment: env ?? environment,
    );
    stdout.add(result.stdout);
    stderr.add(result.stderr);
    if (result.exitCode != 0) {
      throw StateError(
        'Lifecycle command failed (${result.exitCode}): $command',
      );
    }
    return utf8.decode(result.stdout).trim();
  }

  late final String gitExecutable;
  Future<String> git(List<String> args, {String? cwd}) => run([
    gitExecutable,
    '-c',
    'core.autocrlf=false',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'user.name=Archway lifecycle fixture',
    '-c',
    'user.email=fixture@invalid.example',
    ...args,
  ], cwd: cwd ?? fixture.path);
  String? launcher;
  try {
    gitExecutable = findGitExecutable(environment);
    await git(['diff', '--quiet', 'HEAD', '--'], cwd: source);
    final original = await git(['rev-parse', 'HEAD'], cwd: source);
    final originalTree = await git(['rev-parse', 'HEAD^{tree}'], cwd: source);
    await git([
      'clone',
      '--no-hardlinks',
      '--no-checkout',
      source,
      fixture.path,
    ], cwd: base.path);
    await git(['checkout', '--detach', original]);
    final pubspec = File(p.join(fixture.path, 'pubspec.yaml'));
    final cli = File(
      p.join(fixture.path, 'lib', 'src', 'cli', 'cli_output.dart'),
    );
    final pubspecText = pubspec.readAsStringSync();
    final cliText = cli.readAsStringSync();
    final versionMarker = RegExp(r'^version: ([^\r\n]+)$', multiLine: true);
    final release = versionMarker.firstMatch(pubspecText)?.group(1);
    if (release == null ||
        release == predecessorVersion ||
        !cliText.contains("const archwayVersion = '$release';")) {
      throw StateError('Release version markers must agree');
    }
    pubspec.writeAsStringSync(
      replaceVersionMarker(
        pubspecText,
        versionMarker,
        'version: $predecessorVersion',
      ),
    );
    cli.writeAsStringSync(
      replaceVersionMarker(
        cliText,
        RegExp(r"^const archwayVersion = '[^']+';", multiLine: true),
        "const archwayVersion = '$predecessorVersion';",
      ),
    );
    await git(['add', 'pubspec.yaml', 'lib/src/cli/cli_output.dart']);
    final changed = (await git(['diff', '--cached', '--name-only'])).split('\n')
      ..sort();
    if (changed.join('\n') != 'lib/src/cli/cli_output.dart\npubspec.yaml') {
      throw StateError('Predecessor changed more than release markers');
    }
    await git(['commit', '-m', 'Temporary lifecycle predecessor']);
    final predecessor = await git(['rev-parse', 'HEAD']);
    await git(['restore', '--source=$original', '--staged', '--worktree', '.']);
    await git(['commit', '-m', 'Temporary exact release tree']);
    final finalRef = await git(['rev-parse', 'HEAD']);
    if (await git(['rev-parse', 'HEAD^{tree}']) != originalTree) {
      throw StateError('Lifecycle final fixture is not the exact release tree');
    }
    // Seed only ordinary hosted dependency bytes, never shared links or Git
    // checkouts. Installs and probes cannot mutate the driver's package cache.
    final driverCache = Platform.environment['PUB_CACHE'];
    if (driverCache != null) {
      for (final name in ['hosted', 'hosted-hashes']) {
        final from = Directory(p.join(driverCache, name));
        if (from.existsSync())
          copyDirectory(from, Directory(p.join(cache.path, name)));
      }
    }
    Future<void> install(String ref) async {
      final descriptor = jsonEncode({
        'git': {'url': fixture.path, 'ref': ref},
      });
      final output = await run([
        Platform.resolvedExecutable,
        'install',
        'archway@$descriptor',
      ]);
      final matches = RegExp(
        r'^Installed: (.+)$',
        multiLine: true,
      ).allMatches(output).toList();
      if (matches.length != 1)
        throw StateError('Expected exactly one installed launcher');
      final next = p.normalize(p.absolute(matches.single[1]!.trim()));
      if (!p.isWithin(base.path, next) ||
          !File(next).existsSync() ||
          (launcher != null && launcher != next)) {
        throw StateError(
          'SDK launcher escaped isolation or changed identity: $next',
        );
      }
      launcher = next;
    }

    Future<void> verify(String version, String stage) async {
      final hidden = fixture.renameSync('${fixture.path}-hidden');
      final gitCache = Directory(p.join(cache.path, 'git'));
      final hiddenGit = gitCache.existsSync()
          ? gitCache.renameSync('${gitCache.path}-hidden')
          : null;
      try {
        if (fixture.existsSync() || gitCache.existsSync())
          throw StateError('Source remains available');
        await run(
          [
            Platform.resolvedExecutable,
            '--packages=${p.join(source, '.dart_tool', 'package_config.json')}',
            File.fromUri(Platform.script).path,
            '--probe',
            launcher!,
            version,
          ],
          // Native Windows harness DLLs are prepared under this driver tree.
          // installed.probe itself executes every product command in a foreign cwd.
          cwd: source,
          env: {...environment, 'PATH': p.dirname(Platform.resolvedExecutable)},
        );
        stdout.writeln('Lifecycle passed: $stage ($version)');
      } finally {
        hiddenGit?.renameSync(gitCache.path);
        hidden.renameSync(fixture.path);
      }
    }

    Future<void> uninstall() async {
      await run([Platform.resolvedExecutable, 'uninstall', 'archway']);
      if (FileSystemEntity.typeSync(launcher!, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Uninstall left the installed command');
      }
    }

    await install(predecessor);
    await verify(predecessorVersion, 'initial install');
    await install(finalRef);
    await verify(release, 'update to second revision');
    await install(finalRef);
    await verify(release, 'same-ref reinstall');
    await uninstall();
    await install(finalRef);
    await verify(release, 'fresh reinstall after uninstall');
    await uninstall();
    stdout.writeln(
      'Installation lifecycle passed; exact release tree $originalTree; source $original.',
    );
  } finally {
    // All installation state is owned by this directory, even on failed install.
    if (base.existsSync()) base.deleteSync(recursive: true);
  }
}

void copyDirectory(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entry.path));
    if (entry is Directory) {
      copyDirectory(entry, Directory(target));
    } else if (entry is File) {
      entry.copySync(target);
    } else {
      throw StateError(
        'Hosted cache contains a non-ordinary entry: ${entry.path}',
      );
    }
  }
}
