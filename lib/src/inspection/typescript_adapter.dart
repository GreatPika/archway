part of 'inspection.dart';

class _TypeScriptAdapter {
  final _RuntimeProcesses runtime;
  _TypeScriptAdapter(this.runtime);
  String? executable;
  String? helper;
  String? nodeVersion;
  String? compilerVersion;
  bool prepared = false;
  Object? preparationError;
  String preparationCode = 'NODE_UNAVAILABLE';

  Map<String, String> get environment => Map.fromEntries(
    Platform.environment.entries.where(
      (e) =>
          !e.key.toUpperCase().startsWith('NODE_') &&
          !e.key.toUpperCase().startsWith('LD_') &&
          !e.key.toUpperCase().startsWith('DYLD_'),
    ),
  );

  Future<void> prepare(String root) async {
    if (prepared) return;
    prepared = true;
    try {
      final cwd = await Directory.current.resolveSymbolicLinks();
      for (final entry in (Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      )) {
        if (entry.isEmpty || !p.isAbsolute(entry)) continue;
        final dir = p.normalize(entry);
        if (dir == cwd || dir == root || p.isWithin(root, dir)) continue;
        final candidate = p.join(dir, Platform.isWindows ? 'node.exe' : 'node');
        if (!await File(candidate).exists()) continue;
        _symlinkHops(candidate);
        final canonical = await File(candidate).resolveSymbolicLinks();
        if (canonical == root ||
            p.isWithin(root, canonical) ||
            p.dirname(canonical) == cwd)
          continue;
        executable = canonical;
        break;
      }
      if (executable == null)
        throw const FormatException('No external Node executable on PATH.');
      preparationCode = 'TYPESCRIPT_ASSETS_UNAVAILABLE';
      final assets = (await InstallationLayout.resolve()).typescriptAssets;
      await _verifyAssets(assets);
      helper = p.join(assets, 'helper.cjs');
      preparationCode = 'NODE_UNAVAILABLE';
      final output = await runtime.run(
        executable!,
        environment,
        ['--version'],
        const [],
        timeout: const Duration(seconds: 5),
        stdoutLimit: 64 * 1024,
        stderrLimit: 64 * 1024,
        totalLimit: 64 * 1024,
      );
      final version = utf8.decode(output).trim();
      if (version != 'v24.21.0')
        throw FormatException('Node 24.21.0 required; found $version.');
      nodeVersion = '24.21.0';
    } catch (error) {
      preparationError = error;
    }
  }

  Future<void> _verifyAssets(String assets) async {
    final normalized = p.normalize(assets);
    // Verify every runtime-loaded module, compiler library, and its ancestor.
    // Only the generated vendor tree is loaded; no node_modules fallback.
    for (final directory in [
      p.dirname(normalized),
      normalized,
      p.join(normalized, 'vendor'),
      p.join(normalized, 'vendor', 'typescript'),
      p.join(normalized, 'vendor', 'yaml'),
    ]) {
      if (await FileSystemEntity.type(directory, followLinks: false) !=
              FileSystemEntityType.directory ||
          await Directory(directory).resolveSymbolicLinks() != directory) {
        throw const FormatException(
          'Bundled asset directory is missing or aliased.',
        );
      }
    }
    for (final dependency in ['typescript', 'yaml']) {
      await for (final entry in Directory(
        p.join(normalized, 'vendor', dependency),
      ).list(recursive: true, followLinks: false)) {
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (!(type == FileSystemEntityType.file ||
                type == FileSystemEntityType.directory) ||
            await entry.resolveSymbolicLinks() != entry.path) {
          throw const FormatException(
            'Bundled assets must be ordinary, unaliased installation files.',
          );
        }
      }
    }
    for (final required in [
      'helper.cjs',
      'framing.cjs',
      'trace.cjs',
      'packages.cjs',
      'pnpm.cjs',
      'pnpm-path.cjs',
      'node-origin.cjs',
      'version-request.cjs',
      'vendor/yaml/package.json',
      'vendor/yaml/dist/index.js',
      'package.json',
      'vendor/typescript/package.json',
      'vendor/typescript/lib/typescript.js',
    ]) {
      final path = p.joinAll([normalized, ...required.split('/')]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await File(path).resolveSymbolicLinks() != path) {
        throw const FormatException(
          'Bundled TypeScript assets are incomplete.',
        );
      }
    }
  }

  Future<ProjectEvidence> inspect(ProjectRequest request) async {
    await prepare(request.selection.root);
    try {
      if (preparationError != null) throw preparationError!;
      if (runtime.launchBlocked)
        throw const FormatException(
          'Previous helper termination was not confirmed.',
        );
      final requestBytes = utf8.encode(jsonEncode(_requestEnvelope(request)));
      if (requestBytes.length > 8 * 1024 * 1024)
        throw const FormatException('Helper request exceeds 8 MiB.');
      await _verifyAssets(p.dirname(helper!));
      final output = await runtime.run(
        executable!,
        environment,
        [helper!],
        requestBytes,
        timeout: const Duration(seconds: 120),
        stdoutLimit: 64 * 1024 * 1024,
        stderrLimit: 256 * 1024,
      );
      final evidence = await _validateHelper(request, output);
      if (!evidence.toolErrors.any(
        (e) =>
            (e['code'] as String).contains('COMPILER') ||
            e['code'] == 'TYPESCRIPT_LOAD_FAILED' ||
            (e['code'] as String).contains('TYPESCRIPT_VERSION'),
      )) {
        compilerVersion = '5.9.3';
      }
      return evidence;
    } catch (error) {
      return ProjectEvidence(
        request,
        'failed',
        [],
        {
          for (final file in request.expectedFiles)
            file: {
              'path': file,
              'membership': 'unknown',
              'coverage': 'failed',
              'input_id': null,
            },
        },
        [],
        [],
        [],
        [
          if (error is _RuntimeFailure && error.cleanupUnconfirmed)
            _cleanupDiagnostic(),
          {
            'code': preparationError == null
                ? 'TYPESCRIPT_HELPER_FAILED'
                : preparationCode,
            'message': error.toString(),
            'path': null,
            'source_range': null,
          },
        ],
      );
    }
  }
}

Map<String, Object?> _requestEnvelope(ProjectRequest request) => {
  'protocol_version': 2,
  'request_id': request.requestId,
  'project_id': request.project.id,
  'root_uri': _uri(request.selection.root),
  'config_path': request.project.tsconfig,
  'expected_files': request.expectedFiles,
};
