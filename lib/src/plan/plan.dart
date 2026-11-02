import 'policy_definition.dart';
import 'repository_path.dart';

class Plan {
  int get projectCount => projects.length;
  final List<PlanProject> projects;
  int get nodeCount => nodes.length;
  final List<String> scope;
  final List<String> exclude;
  final List<PlanNode> nodes;

  /// Internal construction seam for normalized, schema-checked policy values.
  /// The loader alone constructs production plans; it completes cross-node
  /// validation before exposing the plan. All collections are copied immutably.
  Plan.validated(
    List<PlanProject> projects,
    List<String> scope,
    List<String> exclude,
    List<PlanNode> nodes,
  ) : projects = List.unmodifiable(projects),
      scope = List.unmodifiable(scope),
      exclude = List.unmodifiable(exclude),
      nodes = List.unmodifiable(nodes);

  Ownership owner(String raw) {
    final path = normalizeRepositoryPath(raw);
    if (exclude.any((p) => repositoryPathMatches(p, path)))
      return Ownership(path, 'excluded', null);
    if (!scope.any((p) => repositoryPathMatches(p, path)))
      return Ownership(path, 'outside_scope', null);
    for (final node in nodes) {
      if (node.owns.any((p) => repositoryPathMatches(p, path)))
        return Ownership(path, 'owned', node.id);
    }
    return Ownership(path, 'unowned', null);
  }

  Map<String, Object?>? node(String id) {
    final matches = nodes.where((n) => n.id == id);
    if (matches.isEmpty) return null;
    final value = matches.single;
    Map<String, Object?> neighbor(PlanNode n) => {
      'id': n.id,
      'responsibility': n.responsibility,
    };
    return {
      'id': value.id,
      'responsibility': value.responsibility,
      'owns': value.owns,
      'public': value.public,
      'contracts': value.contracts,
      'allows': nodes
          .where((n) => value.allows.contains(n.id))
          .map(neighbor)
          .toList(),
      'allowed_dependents': nodes
          .where((n) => n.allows.contains(id))
          .map(neighbor)
          .toList(),
    };
  }

  Map<String, Object?> catalogue({int offset = 0, int? limit}) {
    if (offset < 0 || (limit != null && limit < 1)) {
      throw ArgumentError('Invalid catalogue pagination.');
    }
    final start = offset > nodes.length ? nodes.length : offset;
    final remaining = nodes.length - start;
    final count = limit == null || limit > remaining ? remaining : limit;
    final selected = nodes
        .getRange(start, start + count)
        .map(
          (n) => {
            'id': n.id,
            'responsibility': n.responsibility,
            'owns_count': n.owns.length,
          },
        )
        .toList();
    return {
      'mode': 'catalogue',
      'nodes': selected,
      'total': nodes.length,
      'omitted': nodes.length - selected.length,
      'offset': offset,
      'limit': limit,
    };
  }

  List<({String id, String responsibility, List<String> allows})>
  declaredProjection() => List.unmodifiable(
    nodes.map(
      (n) => (id: n.id, responsibility: n.responsibility, allows: n.allows),
    ),
  );

  PolicyDecision allows(String from, String to) {
    final source = nodes.where((n) => n.id == from).firstOrNull;
    final target = nodes.where((n) => n.id == to).firstOrNull;
    if (source == null || target == null)
      throw ArgumentError('Unknown node ID.');
    if (from == to) return const PolicyDecision('allowed', 'same_owner');
    return source.allows.contains(to)
        ? const PolicyDecision('allowed', 'declared_allow')
        : const PolicyDecision('denied', 'not_allowed');
  }

  PolicyDecision allowsPaths(String from, String to) {
    final source = owner(normalizeRepositoryPath(from, file: true));
    final target = owner(normalizeRepositoryPath(to, file: true));
    if (source.ownerId == null || target.ownerId == null)
      return const PolicyDecision('undetermined', 'ownership_unknown');
    final module = allows(source.ownerId!, target.ownerId!);
    if (module.reason != 'declared_allow') return module;
    return nodes
            .singleWhere((n) => n.id == target.ownerId)
            .public
            .contains(target.path)
        ? module
        : const PolicyDecision('denied', 'target_not_public');
  }
}
