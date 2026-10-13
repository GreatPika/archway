// Explicit post-activation setup. Ordinary Archway commands never repair files.
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/installation_layout.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isNotEmpty) {
      throw UnsupportedError('Usage: dart pub global run archway:setup');
    }
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      throw UnsupportedError(
        'Pub launcher setup requires Linux, macOS or Windows.',
      );
    }
    final layout = await InstallationLayout.resolve();
    final pubspec = layout.root.uri.resolve('pubspec.yaml').toFilePath();
    InstallationLayout.requireOrdinaryFile(pubspec);
    final version = loadYaml(File(pubspec).readAsStringSync())['version'];
    final homeKey = Platform.isWindows ? 'LOCALAPPDATA' : 'HOME';
    final home = Platform.environment[homeKey];
    final selectedCache =
        Platform.environment['PUB_CACHE'] ??
        (home == null
            ? throw UnsupportedError('Set PUB_CACHE or $homeKey to locate pub.')
            : Platform.isWindows
            ? path.join(home, 'Pub', 'Cache')
            : path.join(home, '.pub-cache'));
    final cache = path.normalize(path.absolute(selectedCache));
    if (Directory(cache).resolveSymbolicLinksSync() != cache) {
      throw UnsupportedError('Pub cache is aliased.');
    }
    final launcher = File(
      path.join(cache, 'bin', Platform.isWindows ? 'archway.bat' : 'archway'),
    );
    InstallationLayout.requireOrdinaryFile(launcher.path);
    final encoding = Platform.isWindows ? systemEncoding : utf8;
    final originalBytes = launcher.readAsBytesSync();
    final original = encoding.decode(originalBytes);
    if (!_sameBytes(encoding.encode(original), originalBytes)) {
      throw UnsupportedError('Pub launcher encoding does not round-trip.');
    }
    const sdk = '3.13.3';
    final header =
        '''#!/usr/bin/env sh
# This file was created by pub v$sdk.
# Package: archway
# Version: $version
# Executable: archway
# Script: archway
''';
    const fallback = 'dart pub global run archway:archway "\$@"\n';
    final pathLauncher = Platform.isWindows
        ? '${_windowsHeader(version)}call dart pub global run archway:archway %*\n'
        : '$header$fallback';
    if (original == pathLauncher) {
      stdout.writeln('The path-activated pub launcher needs no repair.');
      return;
    }
    final global = path.join(cache, 'global_packages', 'archway');
    final config = path.join(global, '.dart_tool', 'package_config.json');
    InstallationLayout.requireOrdinaryFile(config);
    final packages = await loadPackageConfigUri(File(config).uri);
    if (packages['archway']?.root != layout.root.uri) {
      throw UnsupportedError('The active pub package differs from this setup.');
    }
    final snapshot = path.join(global, 'bin', 'archway.dart-$sdk.snapshot');
    String template(String testPath, String dartPath) =>
        '''${header}if [ -f $testPath ]; then
  dart $dartPath "\$@"
  # The VM exits with code 253 if the snapshot version is out-of-date.
  # If it is, we need to delete it and run "pub global" manually.
  exit_code=\$?
  if [ \$exit_code != 253 ]; then
    exit \$exit_code
  fi
fi
$fallback''';
    final generated = Platform.isWindows
        ? _windowsTemplate(version, snapshot)
        : template(snapshot, '"$snapshot"');
    final fixed = Platform.isWindows
        ? generated.replaceFirst(
            'goto eof\n:error\nexit /b %errorlevel%\n:eof\n',
            ':error\nexit /b %errorlevel%\n',
          )
        : template(_shellLiteral(snapshot), _shellLiteral(snapshot));
    if (original == fixed) {
      stdout.writeln('The pub launcher is already repaired.');
      return;
    }
    if (original != generated) {
      throw UnsupportedError(
        'Unrecognized pub launcher; only the exact Dart $sdk Archway launcher '
        'is supported. Nothing was changed.',
      );
    }
    final mode = launcher.statSync().mode & 0x1ff;
    final temporary = launcher.parent.createTempSync('.archway-setup-');
    try {
      final replacement = File(
        path.join(temporary.path, path.basename(launcher.path)),
      );
      replacement.writeAsStringSync(fixed, encoding: encoding, flush: true);
      if (Platform.isWindows) {
        if ((replacement.statSync().mode & 0x1ff) != mode) {
          throw UnsupportedError('Cannot preserve Windows launcher mode.');
        }
      } else {
        final chmod = await Process.run('/bin/chmod', [
          mode.toRadixString(8),
          replacement.path,
        ]);
        if (chmod.exitCode != 0) {
          throw FileSystemException(
            'Cannot preserve launcher mode',
            launcher.path,
          );
        }
      }
      InstallationLayout.requireOrdinaryFile(launcher.path);
      if (!_sameBytes(launcher.readAsBytesSync(), originalBytes) ||
          (launcher.statSync().mode & 0x1ff) != mode) {
        throw UnsupportedError('The pub launcher changed during setup.');
      }
      replacement.renameSync(launcher.path);
    } finally {
      temporary.deleteSync(recursive: true);
    }
    stdout.writeln(
      'Repaired the Archway pub launcher. '
      'Run this setup again after each pub activation or update.',
    );
  } catch (error) {
    stderr.writeln('Archway pub setup failed: $error');
    exitCode = 1;
  }
}

String _shellLiteral(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

String _windowsHeader(Object? version) =>
    '''@echo off
rem This file was created by pub v3.13.3.
rem Package: archway
rem Version: $version
rem Executable: archway
rem Script: archway
''';

String _windowsTemplate(Object? version, String snapshot) {
  // Exact pinned pub template, including its path-length padding and encoding.
  final padding = ' ' * (260 - snapshot.length);
  return '''${_windowsHeader(version)}if exist "$snapshot" $padding(
  call dart "$snapshot" $padding%*
  rem The VM exits with code 253 if the snapshot version is out-of-date.
  rem If it is, we need to delete it and run "pub global" manually.
  if not errorlevel 253 (
    goto error
  )
  call dart pub global run archway:archway %*
) else (
  call dart pub global run archway:archway %*
)
goto eof
:error
exit /b %errorlevel%
:eof
''';
}
