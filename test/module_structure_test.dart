import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// These checks protect implementation ownership, not a public embedding API.
void main() {
  final root = Directory('lib').absolute.path;
  final files = Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  final imports = <String, Set<String>>{};
  final parts = <String>[];
  for (final file in files) {
    final name = p.relative(file.path, from: root).replaceAll('\\', '/');
    final directives = parseString(content: file.readAsStringSync())
        .unit
        .directives;
    imports[name] = {};
    for (final directive in directives) {
      if (directive is PartDirective || directive is PartOfDirective)
        parts.add(name);
      if (directive is! NamespaceDirective) continue;
      for (final uri in [
        directive.uri.stringValue,
        ...directive.configurations.map((c) => c.uri.stringValue),
      ]) {
        if (uri == null) continue;
        imports[name]!.add(
          uri.startsWith('package:archway/')
              ? uri.substring('package:archway/'.length)
              : Uri.parse(uri).hasScheme
              ? uri
              : p.posix.normalize(p.posix.join(p.posix.dirname(name), uri)),
        );
      }
    }
  }
  Set<String> dependencies(String start, [Set<String>? seen]) {
    final result = seen ?? <String>{};
    for (final target in imports[start] ?? <String>{}) {
      if (result.add(target) && imports.containsKey(target))
        dependencies(target, result);
    }
    return result;
  }

  test(
    'production files are independent libraries without handwritten parts',
    () {
      expect(parts, isEmpty);
    },
  );
  test('production import and export graph is acyclic', () {
    for (final name in imports.keys) {
      expect(dependencies(name), isNot(contains(name)), reason: name);
    }
  });
  test(
    'policy model and evidence assessment are independent of acquisition',
    () {
      for (final name in [
        'src/plan/plan.dart',
        'src/inspection/assessment.dart',
      ]) {
        expect(imports, contains(name));
        final reachable = dependencies(name);
        expect(
          reachable.where(
            (s) =>
                s == 'dart:io' ||
                s.contains('package:analyzer/') ||
                s.endsWith('/policy_loader.dart') ||
                s.endsWith('/corpus.dart') ||
                s.endsWith('/observations.dart') ||
                s.endsWith('/runtime_process.dart') ||
                s.contains('/cli/'),
          ),
          isEmpty,
          reason: '$name reaches acquisition or transport',
        );
      }
    },
  );
  test('Dart facts cannot import policy evaluation or transport', () {
    final adapters = imports.keys.where(
      (s) => s.startsWith('src/inspection/dart_'),
    );
    expect(adapters, isNotEmpty);
    for (final name in adapters) {
      expect(
        dependencies(name).where(
          (s) =>
              s == 'src/plan/plan.dart' ||
              s.endsWith('/policy_loader.dart') ||
              s.endsWith('/assessment.dart') ||
              s.endsWith('/report.dart') ||
              s.endsWith('/inspection.dart') ||
              s.contains('/cli/'),
        ),
        isEmpty,
        reason: name,
      );
    }
  });
  test('responsibility seams exist and retain directional dependencies', () {
    for (final name in [
      'src/plan/policy_loader.dart',
      'src/plan/policy_yaml.dart',
      'src/plan/policy_schema.dart',
      'src/plan/policy_definition.dart',
      'src/plan/repository_path.dart',
      'src/inspection/assessment.dart',
      'src/inspection/corpus.dart',
      'src/inspection/input_observation.dart',
      'src/inspection/dart_runtime.dart',
      'src/inspection/dart_context.dart',
      'src/inspection/dart_directives.dart',
      'src/cli/invocation.dart',
      'src/cli/cli_output.dart',
      'src/cli/mermaid.dart',
      'src/bootstrap/startup_files.dart',
    ]) {
      expect(imports, contains(name), reason: 'Missing owning library $name');
    }
    expect(
      dependencies('src/inspection/dart_context.dart').where(
        (s) =>
            s.endsWith('/runtime_process.dart') ||
            s.endsWith('/dart_runtime.dart'),
      ),
      isEmpty,
    );
    expect(
      dependencies('src/inspection/runtime_process.dart')
          .where((s) => s.startsWith('package:analyzer/')),
      isEmpty,
    );
    for (final entry in imports.entries) {
      final owner = entry.key.split('/')[1];
      final allowed = switch (owner) {
        'cli' => {'cli', 'plan', 'inspection', 'bootstrap', 'native'},
        'inspection' => {'inspection', 'plan', 'native'},
        'bootstrap' => {'bootstrap', 'native'},
        'plan' => {'plan'},
        'native' => {'native'},
        _ => <String>{},
      };
      for (final target in entry.value.where((s) => imports.containsKey(s))) {
        expect(
          allowed,
          contains(target.split('/')[1]),
          reason: '${entry.key} -> $target',
        );
      }
    }
  });
}
