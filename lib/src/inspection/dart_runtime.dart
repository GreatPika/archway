import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dart_resources.dart';
import 'dart_flutter.dart';
import 'runtime_process.dart';
import 'input_observation.dart';
import 'physical_paths.dart';

class DartRuntime {
  final RuntimeProcesses _runtime;
  DartRuntime(this._runtime);
  String? _sdkVersion;
  String? get sdkVersion => _sdkVersion;
  String? _sdkPath;
  String? get sdkPath => _sdkPath;
  FlutterSdk? _flutterSdk;
  FlutterSdk? get flutterSdk => _flutterSdk;

  bool _prepared = false;
  Object? _preparationError;
  List<InputObservation> _preparationInputs = [];

  Future<void> prepare(String root, DartResources resources) async {
    if (_prepared) {
      resources.observations.addAll(
        _preparationInputs.map(
          (o) => InputObservation(
            o.kind,
            o.observed,
            o.canonical,
            o.hash,
            o.role,
            resources.project,
            o.symlinkHops,
          ),
        ),
      );
      if (_preparationError != null) throw _preparationError!;
      return;
    }
    _prepared = true;
    try {
      await _prepareRuntime(root, resources);
    } catch (error) {
      _preparationError = error;
      rethrow;
    } finally {
      _preparationInputs = List.of(resources.observations);
    }
  }

  Future<void> _prepareRuntime(String root, DartResources resources) async {
    final cwd = await Directory.current.resolveSymbolicLinks();
    String? executable;
    for (final entry in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      if (entry.isEmpty || !p.isAbsolute(entry)) continue;
      final directory = p.normalize(entry);
      if (directory == cwd || directory == root || p.isWithin(root, directory))
        continue;
      final candidate = File(
        p.join(directory, Platform.isWindows ? 'dart.exe' : 'dart'),
      );
      if (!await candidate.exists()) continue;
      symlinkHops(candidate.path);
      final canonical = await candidate.resolveSymbolicLinks();
      if (canonical == root ||
          p.isWithin(root, canonical) ||
          p.dirname(canonical) == cwd)
        continue;
      // A Flutter bin/dart entry is a launcher. Select its prepared embedded
      // binary directly: never run Flutter CLI or let it populate the cache.
      final embedded = resources.getFile(
        p.join(
          p.dirname(canonical),
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      final selected = embedded.exists
          ? embedded.resolveSymbolicLinksSync().path
          : canonical;
      if (selected == root ||
          p.isWithin(root, selected) ||
          p.dirname(selected) == cwd)
        continue;
      executable = selected;
      break;
    }
    if (executable == null)
      throw const FormatException('No external Dart SDK on PATH.');
    _sdkPath = p.dirname(p.dirname(executable));
    final version = resources
        .getFile(p.join(sdkPath!, 'version'))
        .readAsStringSync()
        .trim();
    if (version != '3.13.3')
      throw FormatException('Dart SDK 3.13.3 required; found $version.');
    final output = utf8.decode(
      await _runtime.run(
        executable,
        _runtime.environment,
        ['--suppress-analytics', '--version'],
        const [],
        timeout: const Duration(seconds: 5),
        stdoutLimit: 65536,
        stderrLimit: 65536,
        totalLimit: 65536,
      ),
    );
    if (!output.startsWith('Dart SDK version: 3.13.3 '))
      throw const FormatException('Dart SDK executable and metadata disagree.');
    resources
        .getFile(p.join(sdkPath!, 'lib', 'libraries.json'))
        .readAsStringSync();
    resources
        .getFile(p.join(sdkPath!, 'lib', 'core', 'core.dart'))
        .readAsStringSync();
    _flutterSdk = FlutterSdk.selected(sdkPath!, resources);
    _sdkVersion = version;
  }
}
