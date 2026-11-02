import '../../tool/validation/json_values.dart';
import '../compatibility/lexical_reference.dart';

/// Finite policy-only specification; no filesystem or compiler execution.
(String?, String) ownership(Map policy, String raw) {
  final path = normalize(raw);
  if ((policy['exclude'] as List).any((x) => matches(normalize(x), path))) {
    return (null, 'excluded');
  }
  if (!(policy['scope'] as List).any((x) => matches(normalize(x), path))) {
    return (null, 'outside_scope');
  }
  final owners = [
    for (final node in policy['nodes'])
      if ((node['owns'] as List).any((x) => matches(normalize(x), path)))
        node['id'] as String,
  ];
  _require(
    owners.length <= 1,
    'overlapping owners require prior policy rejection',
  );
  return owners.isEmpty ? (null, 'unowned') : (owners.single, 'owned');
}

(String, String) decide(
  Map policy,
  String source,
  String target, {
  String mode = 'paths',
}) {
  final nodes = {for (final node in policy['nodes']) node['id']: node};
  String? a, b;
  if (mode == 'ids') {
    _require(
      nodes.containsKey(source) && nodes.containsKey(target),
      'UNKNOWN_NODE_ID',
    );
    a = source;
    b = target;
  } else {
    _require(
      [source, target].every(
        (value) =>
            !['.', '..'].contains(value.replaceAll(r'\', '/').split('/').last),
      ),
      'USAGE_ERROR',
    );
    source = normalize(source);
    target = normalize(target);
    _require(!source.endsWith('/') && !target.endsWith('/'), 'USAGE_ERROR');
    a = ownership(policy, source).$1;
    b = ownership(policy, target).$1;
    if (a == null || b == null) return ('undetermined', 'ownership_unknown');
  }
  if (a == b) return ('allowed', 'same_owner');
  if (!(nodes[a]['allows'] as List).contains(b))
    return ('denied', 'not_allowed');
  if (mode == 'paths' &&
      !(nodes[b]['public'] as List).map(normalize).contains(target))
    return ('denied', 'target_not_public');
  return ('allowed', 'declared_allow');
}

void _require(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

void validatePublic(Map policy) {
  final nodes = policy['nodes'] as List;
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i] as Map;
    _require(
      node.containsKey('public'),
      'POLICY_SCHEMA_INVALID: /nodes/$i/public',
    );
    final public = node['public'] as List;
    for (var j = 0; j < public.length; j++) {
      final pointer = '/nodes/$i/public/$j';
      final raw = public[j];
      late String path;
      try {
        path = normalize(raw);
      } on FormatException {
        throw FormatException('POLICY_PATH_INVALID: $pointer');
      }
      _require(
        !path.endsWith('/') &&
            ![
              '.',
              '..',
            ].contains((raw as String).replaceAll(r'\', '/').split('/').last),
        'PUBLIC_PATH_NOT_FILE: $pointer',
      );
      final (owner, state) = ownership(policy, path);
      _require(state != 'excluded', 'PUBLIC_PATH_EXCLUDED: $pointer');
      _require(state != 'outside_scope', 'PUBLIC_PATH_OUTSIDE_SCOPE: $pointer');
      _require(owner == node['id'], 'PUBLIC_PATH_NOT_OWNED: $pointer');
    }
  }
}

String? edgeViolation(Map policy, Map edge) {
  // Only a resolved, known local edge is eligible for a boundary decision.
  final resolution = edge['resolution'];
  if (resolution['kind'] != 'local') return null;
  final target = resolution['path'];
  if (target == null) return 'LOCAL_TARGET_OUTSIDE_SCOPE';
  final (_, state) = ownership(policy, target);
  if (state != 'owned') {
    return {
      'excluded': 'LOCAL_TARGET_EXCLUDED',
      'outside_scope': 'LOCAL_TARGET_OUTSIDE_SCOPE',
      'unowned': 'LOCAL_TARGET_UNOWNED',
    }[state];
  }
  // SOURCE_UNOWNED is a separate file diagnostic, not duplicated per edge.
  if (ownership(policy, edge['source']).$1 == null) return null;
  final (_, reason) = decide(policy, edge['source'], target);
  return {
    'not_allowed': 'DEPENDENCY_NOT_ALLOWED',
    'target_not_public': 'TARGET_NOT_PUBLIC',
  }[reason];
}

void verifyLinked(Map result, Map policy) {
  validatePublic(policy);
  final payload = result['payload'];
  if (result['command'] == 'allows') {
    final mode = payload['mode'];
    final (source, target) = mode == 'ids'
        ? (payload['from_id'], payload['to_id'])
        : (payload['from']['path'], payload['to']['path']);
    _require(
      (payload['policy_decision'], payload['reason']) ==
          decide(policy, source, target, mode: mode),
      'decision differs from linked policy',
    );
    if (mode == 'paths') {
      for (final side in ['from', 'to']) {
        _require(
          (payload[side]['owner_id'], payload[side]['ownership']) ==
              ownership(policy, payload[side]['path']),
          'ownership differs from linked policy',
        );
      }
    }
  }
  if (result['command'] == 'check') {
    final edges = payload['facts']['edges'] as List;
    // This finite fixture oracle covers owned sources only. File-level discovery
    // and compiler diagnostics are outside this linked-fixture comparison.
    _require(
      edges.every((edge) => ownership(policy, edge['source']).$1 != null),
      'linked fixture requires owned sources',
    );
    final expected = <List>[];
    for (final edge in edges) {
      final code = edgeViolation(policy, edge);
      if (code == null) continue;
      String? pointer;
      if (code == 'TARGET_NOT_PUBLIC' || code == 'DEPENDENCY_NOT_ALLOWED') {
        final path = code == 'TARGET_NOT_PUBLIC'
            ? edge['resolution']['path']
            : edge['source'];
        final owner = ownership(policy, path).$1;
        final index = (policy['nodes'] as List).indexWhere(
          (node) => node['id'] == owner,
        );
        pointer =
            '/nodes/$index/${code == 'TARGET_NOT_PUBLIC' ? 'public' : 'allows'}';
      }
      expected.add([
        code,
        pointer,
        edge['source'],
        edge['source_range'],
        edge['project_id'],
      ]);
    }
    final actual = [
      for (final diagnostic in payload['violations'])
        [
          diagnostic['code'],
          diagnostic['rule_pointer'],
          diagnostic['path'],
          diagnostic['source_range'],
          diagnostic['project_id'],
        ],
    ];
    // Compare multisets, retaining duplicate diagnostics as evidence mismatches.
    final remaining = [...expected];
    for (final diagnostic in actual) {
      final index = remaining.indexWhere(
        (value) => sameJson(value, diagnostic),
      );
      _require(
        index >= 0,
        'diagnostic evidence differs from linked resolved-edge policy',
      );
      remaining.removeAt(index);
    }
    _require(
      remaining.isEmpty,
      'diagnostic evidence differs from linked resolved-edge policy',
    );
  }
}
