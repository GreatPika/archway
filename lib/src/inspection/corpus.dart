import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../plan/plan.dart';
import '../plan/repository_path.dart';
import 'observations.dart';
import 'physical_paths.dart';
import 'project_evidence.dart';
import 'report.dart';

Future<List<String>> enumerateCorpus(
  Plan plan,
  ObservedInputs inputs,
  List<Map<String, Object?>> unknowns,
  List<Map<String, Object?>> warnings,
) async {
  final files = <String>{};
  final visited = <String>{};
  bool excluded(String path) =>
      plan.owner(path).ownership == 'excluded' ||
      plan.exclude.contains('$path/');
  Future<void> visit(String relative, {bool descend = true}) async {
    if (!visited.add('$relative|$descend')) return;
    final native = p.join(inputs.root, relative == './' ? '' : relative);
    try {
      if (normalizeRepositoryPath(relative) != relative ||
          unicode.nfc(relative) != relative) {
        throw const FormatException('Noncanonical source spelling.');
      }
      if (excluded(relative)) return;
      final type = await FileSystemEntity.type(native, followLinks: false);
      if (type == FileSystemEntityType.link) {
        unknowns.add(
          inspectionDiagnostic(
            'SOURCE_SYMLINK',
            'Selected source paths must not traverse a symlink.',
            path: relative,
          ),
        );
        return;
      }
      if (type == FileSystemEntityType.directory) {
        inputs.add(await observeInput(native, 'inventory'));
        if (!descend) return;
        final entries = await observedDirectoryEntries(native).toList();
        entries.sort((a, b) => comparePlanText(a.path, b.path));
        for (final entry in entries) {
          await visit(repositoryRelativePath(inputs.root, entry.path)!);
        }
      } else if (type == FileSystemEntityType.file) {
        if (sourceLanguage(relative) != null) {
          files.add(relative);
          inputs.add(await observeInput(native, 'source'));
        } else if (plan.scope.contains(relative)) {
          warnings.add(
            inspectionDiagnostic(
              'UNSUPPORTED_SCOPE_FILE',
              'The explicitly selected file is not a recognized source kind.',
              path: relative,
              severity: 'warning',
            ),
          );
        }
      } else if (type == FileSystemEntityType.notFound) {
        inputs.add(await observeInput(native, 'resolution'));
      } else {
        throw FileSystemException(
          'Selected path is not a regular file.',
          native,
        );
      }
    } catch (error) {
      unknowns.add(
        inspectionDiagnostic(
          'CORPUS_ENUMERATION_FAILED',
          'Cannot enumerate selected input $relative: $error',
          path: publicPhysicalPath(relative),
        ),
      );
    }
  }

  for (final scope in plan.scope) {
    if (excluded(scope)) continue;
    // Inventory each selected prefix before accepting its physical spelling.
    // NFC equality cannot silently substitute a different directory entry.
    var prefix = inputs.root;
    String? refusal;
    try {
      for (final segment
          in scope.split('/').where((s) => s.isNotEmpty && s != '.')) {
        if (await FileSystemEntity.type(prefix, followLinks: false) !=
            FileSystemEntityType.directory)
          break;
        inputs.add(await observeInput(prefix, 'inventory'));
        final entries = await observedDirectoryEntries(prefix).toList();
        final matches = entries.where(
          (entry) => unicode.nfc(p.basename(entry.path)) == segment,
        );
        if (matches.length > 1 ||
            (matches.isNotEmpty &&
                p.basename(matches.single.path) != segment)) {
          refusal = 'PHYSICAL_PATH_AMBIGUOUS';
          break;
        }
        prefix = p.join(prefix, segment);
        final type = await FileSystemEntity.type(prefix, followLinks: false);
        if (type == FileSystemEntityType.link) {
          refusal = 'SOURCE_SYMLINK';
          break;
        }
        if (type != FileSystemEntityType.notFound && matches.isEmpty) {
          refusal = 'PHYSICAL_PATH_AMBIGUOUS';
          break;
        }
      }
      if (refusal != null) {
        unknowns.add(
          inspectionDiagnostic(
            refusal,
            'Selected scope has an unsafe physical identity.',
            path: scope,
          ),
        );
      } else {
        await visit(
          scope == './' ? './' : scope.replaceFirst(RegExp(r'/$'), ''),
          descend: scope.endsWith('/'),
        );
      }
    } catch (error) {
      unknowns.add(
        inspectionDiagnostic(
          'CORPUS_ENUMERATION_FAILED',
          'Cannot inspect selected prefix: $error',
          path: scope,
        ),
      );
    }
  }
  return files.toList()..sort(comparePlanText);
}
