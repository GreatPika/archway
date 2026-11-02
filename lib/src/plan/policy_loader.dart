import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'plan.dart';
import 'policy_definition.dart';
import 'policy_schema.dart';
import 'policy_yaml.dart';
import 'repository_path.dart';

Future<PlanLoad> loadPlan(RepositorySelection selection) async {
  final List<int> bytes;
  try {
    bytes = await File('${selection.root}/${selection.policyPath}')
        .readAsBytes();
  } on FileSystemException catch (error) {
    return PlanLoad('error', null, null, [
      PolicyDiagnostic('POLICY_READ_FAILED', 'error', error.toString()),
    ]);
  }
  final hash = 'sha256:${sha256.convert(bytes)}';
  dynamic policy;
  try {
    policy = parsePolicyYaml(utf8.decode(bytes));
  } catch (error) {
    return PlanLoad('invalid_policy', hash, null, [
      PolicyDiagnostic('POLICY_PARSE_ERROR', 'error', error.toString()),
    ]);
  }
  PlanLoad invalid(String code, String message, String pointer) => PlanLoad(
    'invalid_policy',
    hash,
    null,
    [PolicyDiagnostic(code, 'error', message, pointer)],
  );
  final schemaError = validatePolicySchema(policy);
  if (schemaError != null) {
    return PlanLoad('invalid_policy', hash, null, [schemaError]);
  }
  for (final kind in ['projects', 'nodes']) {
    final ids = <String>{};
    final values = policy[kind] as List;
    for (var i = 0; i < values.length; i++) {
      if (!ids.add(values[i]['id']))
        return invalid(
          kind == 'nodes' ? 'DUPLICATE_NODE_ID' : 'DUPLICATE_PROJECT_ID',
          'Duplicate ID ${values[i]['id']}.',
          '/$kind/$i/id',
        );
    }
  }
  try {
    final projects = <PlanProject>[];
    for (var i = 0; i < (policy['projects'] as List).length; i++) {
      final p = policy['projects'][i];
      projects.add(
        PlanProject(
          p['id'],
          p['adapter'],
          _policyPaths(
            p['package_roots'],
            '/projects/$i/package_roots',
            directory: true,
          ),
          i,
        ),
      );
    }
    projects.sort((a, b) => a.id.compareTo(b.id));
    final warnings = <PolicyDiagnostic>[];
    final nodes = <PlanNode>[];
    for (var i = 0; i < (policy['nodes'] as List).length; i++) {
      final n = policy['nodes'][i];
      for (var j = 0; j < (n['public'] as List).length; j++) {
        final raw = (n['public'][j] as String).replaceAll('\\', '/');
        if (raw.endsWith('/') || {'.', '..'}.contains(raw.split('/').last)) {
          return invalid(
            'PUBLIC_PATH_NOT_FILE',
            'Public entries must be exact files.',
            '/nodes/$i/public/$j',
          );
        }
      }
      final owns = _policyPaths(n['owns'], '/nodes/$i/owns');
      owns.removeWhere(
        (p) =>
            owns.any((other) => other != p && repositoryPathMatches(other, p)),
      );
      final contracts = <String>{};
      final references = (n['contracts'] ?? []) as List;
      for (var j = 0; j < references.length; j++) {
        final raw = references[j] as String;
        final uri = Uri.tryParse(raw);
        final remote =
            uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty;
        final ref = remote ? raw : _policyPath(raw, '/nodes/$i/contracts/$j');
        if (contracts.add(ref) &&
            !remote &&
            !await File('${selection.root}/$ref').exists()) {
          warnings.add(
            PolicyDiagnostic(
              'CONTRACT_NOT_FOUND',
              'warning',
              'Contract reference does not exist.',
              '/nodes/$i/contracts/$j',
              ref,
            ),
          );
        }
      }
      nodes.add(
        PlanNode(
          n['id'],
          n['responsibility'],
          owns,
          _policyPaths(n['public'], '/nodes/$i/public', file: true),
          _strings((n['allows'] as List).where((a) => a != n['id']).toList()),
          _strings(contracts.toList()),
          i,
        ),
      );
    }
    final ids = nodes.map((n) => n.id).toSet();
    for (final node in nodes) {
      final declared = policy['nodes'][node.policyIndex]['allows'] as List;
      for (var j = 0; j < declared.length; j++) {
        if (!ids.contains(declared[j]))
          return invalid(
            'UNKNOWN_NODE_ID',
            'Unknown permission target ${declared[j]}.',
            '/nodes/${node.policyIndex}/allows/$j',
          );
      }
    }
    nodes.sort((a, b) => a.id.compareTo(b.id));
    final plan = Plan.validated(
      projects,
      _policyPaths(policy['scope'], '/scope'),
      _policyPaths(policy['exclude'], '/exclude'),
      nodes,
    );
    for (final node in nodes) {
      final entries = policy['nodes'][node.policyIndex]['owns'] as List;
      for (var j = 0; j < entries.length; j++) {
        final candidate = normalizeRepositoryPath(entries[j]);
        if (nodes
            .where((n) => n.policyIndex < node.policyIndex)
            .any(
              (other) => other.owns.any(
                (p) =>
                    repositoryPathMatches(p, candidate) ||
                    repositoryPathMatches(candidate, p),
              ),
            )) {
          return invalid(
            'OWNERSHIP_OVERLAP',
            'Ownership overlaps another node.',
            '/nodes/${node.policyIndex}/owns/$j',
          );
        }
      }
    }
    for (final node in nodes) {
      final entries = policy['nodes'][node.policyIndex]['public'] as List;
      for (var j = 0; j < entries.length; j++) {
        final owner = plan.owner(entries[j]);
        final code = owner.ownership == 'excluded'
            ? 'PUBLIC_PATH_EXCLUDED'
            : owner.ownership == 'outside_scope'
            ? 'PUBLIC_PATH_OUTSIDE_SCOPE'
            : owner.ownerId != node.id
            ? 'PUBLIC_PATH_NOT_OWNED'
            : null;
        if (code != null)
          return invalid(
            code,
            'Public file must be owned by this node within scope and outside exclusions.',
            '/nodes/${node.policyIndex}/public/$j',
          );
      }
    }
    warnings.addAll(_cycleWarnings(nodes));
    return PlanLoad('ok', hash, plan, [
      ...warnings,
      if ((policy['projects'] as List).isEmpty && nodes.isEmpty)
        const PolicyDiagnostic(
          'EMPTY_PLAN',
          'warning',
          'The policy has no projects or nodes.',
        ),
    ]);
  } on _PolicyPathError catch (error) {
    return invalid('POLICY_PATH_INVALID', error.message, error.pointer);
  }
}

class PlanLoad {
  final String status;
  final String? policyHash;
  final Plan? plan;
  final List<PolicyDiagnostic> diagnostics;
  const PlanLoad(this.status, this.policyHash, this.plan, this.diagnostics);
}

List<String> _policyPaths(
  List values,
  String pointer, {
  bool file = false,
  bool directory = false,
}) => [
  for (var i = 0; i < values.length; i++)
    _policyPath(values[i], '$pointer/$i', file: file, directory: directory),
].toSet().toList()..sort(comparePlanText);
String _policyPath(
  String raw,
  String pointer, {
  bool file = false,
  bool directory = false,
}) {
  try {
    return normalizeRepositoryPath(raw, file: file, directory: directory);
  } on FormatException catch (error) {
    throw _PolicyPathError(error.message, pointer);
  }
}

class _PolicyPathError {
  final String message;
  final String pointer;
  _PolicyPathError(this.message, this.pointer);
}

List<String> _strings(List values) =>
    (values.cast<String>().toSet().toList()..sort(comparePlanText));

List<PolicyDiagnostic> _cycleWarnings(List<PlanNode> nodes) {
  final byId = {for (final n in nodes) n.id: n};
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final active = <String>{};
  final warnings = <PolicyDiagnostic>[];
  var next = 0;
  void visit(String id) {
    index[id] = next;
    low[id] = next++;
    stack.add(id);
    active.add(id);
    for (final target in byId[id]!.allows) {
      if (!index.containsKey(target)) {
        visit(target);
        if (low[target]! < low[id]!) low[id] = low[target]!;
      } else if (active.contains(target) && index[target]! < low[id]!) {
        low[id] = index[target]!;
      }
    }
    if (low[id] == index[id]) {
      final component = <String>[];
      String current;
      do {
        current = stack.removeLast();
        active.remove(current);
        component.add(current);
      } while (current != id);
      if (component.length > 1) {
        component.sort();
        warnings.add(
          PolicyDiagnostic(
            'POLICY_CYCLE',
            'warning',
            'Declared dependency cycle: ${component.join(', ')}.',
            '/nodes/${byId[component.first]!.policyIndex}/allows',
          ),
        );
      }
    }
  }

  for (final node in nodes) {
    if (!index.containsKey(node.id)) visit(node.id);
  }
  return warnings;
}
