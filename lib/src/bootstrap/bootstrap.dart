import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import '../native/native_io.dart';

part 'linux_files.dart';

/// Owns startup file contents and the two-file initialization operation.
class Bootstrap {
  Future<InitResult> initialize(
    String root,
    String template,
    bool dryRun,
  ) async {
    _fault('beforePrepare', root);
    root = await Directory(root).resolveSymbolicLinks();
    if (!await Directory(root).exists())
      throw FileSystemException('Root is not a directory', root);
    // Listing reports inaccessible roots instead of silently treating a failed
    // stat as absence. Names alone suffice, including directories/dangling links.
    final present = <String, List<String>>{};
    await for (final entry in Directory(root).list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      // Only init's two fixed ASCII names use this conservative collision rule.
      final folded = name.replaceAllMapped(
        RegExp('[A-Z]'),
        (match) => match[0]!.toLowerCase(),
      );
      (present[folded] ??= []).add(name);
    }
    final conflicts = [
      for (final path in const ['architecture.yaml', 'ARCHITECTURE.md'])
        if (present.containsKey(path.toLowerCase())) path,
    ];
    final files = [
      PlannedFile(
        'architecture.yaml',
        '# Archway: $template template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      ),
      PlannedFile('ARCHITECTURE.md', _guide),
    ];
    if (conflicts.isNotEmpty || dryRun) {
      return InitResult(
        template: template,
        dryRun: dryRun,
        outcome: conflicts.isEmpty ? 'planned' : 'conflict',
        conflictingPaths: conflicts,
        plannedFiles: dryRun ? files : const [],
        diagnostics: [
          for (final path in conflicts)
            InitDiagnostic(
              'INIT_TARGET_EXISTS',
              'A startup target already exists: ${(present[path.toLowerCase()]!..sort()).join(', ')}. Init never overwrites or merges it.',
              path,
            ),
        ],
      );
    }
    final directory = _LinuxFiles(root, await NativeIo.load());
    final created = <String>[];
    String? currentPath;
    FileSystemException? failure;
    final residual = <String>[];
    try {
      for (final file in files) {
        currentPath = file.path;
        _fault('beforeCreate', file.path);
        final fd = directory.create(file.path);
        created.add(file.path);
        try {
          _fault('beforeWrite', file.path);
          directory.write(fd, file.content);
        } finally {
          directory.close(fd);
        }
      }
    } on FileSystemException catch (error) {
      failure = error;
      for (final path in created) {
        try {
          if (directory.exists(path)) residual.add(path);
        } on FileSystemException {
          residual.add(path); // Uncertain observation cannot authorize cleanup.
        }
      }
    } finally {
      try {
        directory.dispose();
        _fault('afterDispose', root);
      } on FileSystemException catch (error) {
        if (failure == null) {
          failure = error;
          currentPath = null;
          residual.addAll(created);
        }
      }
    }
    final error = failure;
    if (error != null) {
      return InitResult(
        template: template,
        dryRun: false,
        outcome: residual.isEmpty ? 'rolled_back' : 'partial',
        createdPaths: created,
        residualPaths: residual,
        conflictingPaths:
            error is NativeIoException &&
                error.category == IoCategory.exists &&
                currentPath != null
            ? [currentPath]
            : const [],
        diagnostics: [
          InitDiagnostic('INIT_WRITE_FAILED', error.toString(), currentPath),
          for (final path in residual)
            InitDiagnostic(
              'INIT_ROLLBACK_FAILED',
              'Automatic removal cannot be proven identity-safe on this platform. Inspect this residual path and decide manually whether to remove or recover it.',
              path,
            ),
        ],
      );
    }
    return InitResult(
      template: template,
      dryRun: false,
      outcome: 'created',
      createdPaths: files.map((f) => f.path).toList(),
    );
  }
}

class PlannedFile {
  final String path;
  final String content;
  const PlannedFile(this.path, this.content);
}

class InitResult {
  final String template;
  final bool dryRun;
  final String outcome;
  final List<PlannedFile> plannedFiles;
  final List<String> createdPaths;
  final List<String> residualPaths;
  final List<String> conflictingPaths;
  final List<InitDiagnostic> diagnostics;
  const InitResult({
    required this.template,
    required this.dryRun,
    required this.outcome,
    this.plannedFiles = const [],
    this.createdPaths = const [],
    this.residualPaths = const [],
    this.conflictingPaths = const [],
    this.diagnostics = const [],
  });
  List<String> get plannedPaths => const [
    'architecture.yaml',
    'ARCHITECTURE.md',
  ];
}

const _guide = '''# Architecture agent workflow

1. Select the repository explicitly with `archway --root ROOT`. Read commands
   use `architecture.yaml` unless you choose `--policy PATH`. No parent search
   occurs. If either startup file exists, inspect it and ask the user whether
   to keep it or recover it manually. Init never overwrites or merges files.
2. Agree the architecture plan before changing application code. An empty
   policy is a starting point, not a description of the application.
3. Use `archway validate`, `archway node`, `archway node ID`, and
   `archway owner PATH` to obtain complete direct context for proposed files.
4. Check every proposed file dependency with `archway allows --paths FROM TO`.
   Module permission alone does not expose a private target file.
5. Run `archway check` and the application's own tests after changes.
   Incomplete analysis is not a clean result; retain and address known violations.
6. Ask for separate approval before changing policy. Never weaken policy
   automatically to make implementation pass.

You may manually add a pointer to this guide in AGENTS.md after review.
Init does not edit AGENTS.md, CI, or editor settings. Two-file creation is not
crash-atomic; inspect reported residual paths after an unsuccessful rollback.
''';

class InitDiagnostic {
  final String code;
  final String message;
  final String? path;
  const InitDiagnostic(this.code, this.message, this.path);
}

// Fault injection remains private to this owning module, with no CLI option
// or supported embedding interface. Tests observe initialize's returned outcome.
void _fault(String stage, String path) {
  final fault =
      Zone.current[#archwayBootstrapFault] as void Function(String, String)?;
  fault?.call(stage, path);
}
