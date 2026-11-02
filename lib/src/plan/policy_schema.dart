import 'policy_definition.dart';

PolicyDiagnostic? validatePolicySchema(dynamic policy) {
  const keys = ['version', 'projects', 'scope', 'exclude', 'nodes'];
  if (policy is! Map) {
    return PolicyDiagnostic(
      'POLICY_SCHEMA_INVALID',
      'error',
      'Expected a closed policy mapping.',
      '',
    );
  }
  for (final key in policy.keys) {
    if (!keys.contains(key))
      return PolicyDiagnostic(
        'POLICY_SCHEMA_INVALID',
        'error',
        'Unknown policy property.',
        '/${_pointerKey(key as String)}',
      );
  }
  for (final key in keys) {
    if (!policy.containsKey(key) ||
        (key == 'version' ? policy[key] is! int : policy[key] is! List)) {
      return PolicyDiagnostic(
        'POLICY_SCHEMA_INVALID',
        'error',
        'Missing or incorrectly typed $key.',
        '/$key',
      );
    }
  }
  if (policy['version'] != 1) {
    return PolicyDiagnostic(
      'POLICY_VERSION_UNSUPPORTED',
      'error',
      'Only policy version 1 is supported.',
      '/version',
    );
  }
  final shapeError = _validateShape(policy);
  if (shapeError != null) {
    return PolicyDiagnostic(
      'POLICY_SCHEMA_INVALID',
      'error',
      'Invalid policy value.',
      shapeError,
    );
  }
  return null;
}

final _id = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$');
bool _identifier(dynamic value) => value is String && _id.hasMatch(value);
bool _schemaPath(dynamic value) =>
    value is String &&
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(value) &&
    !RegExp(r'[\x00-\x1f*?\[\]{}]').hasMatch(value);

String? _validateShape(Map policy) {
  String? fields(
    dynamic value,
    List<String> required,
    List<String> optional,
    String pointer,
  ) {
    if (value is! Map) return pointer;
    for (final key in value.keys) {
      if (key is! String) return pointer;
      if (![...required, ...optional].contains(key))
        return '$pointer/${_pointerKey(key)}';
    }
    for (final key in required) {
      if (!value.containsKey(key)) return '$pointer/$key';
    }
    return null;
  }

  String? array(
    dynamic value,
    bool Function(dynamic) valid,
    String pointer, {
    bool nonempty = false,
  }) {
    if (value is! List || (nonempty && value.isEmpty)) return pointer;
    for (var i = 0; i < value.length; i++) {
      if (!valid(value[i])) return '$pointer/$i';
    }
    return null;
  }

  for (final key in ['scope', 'exclude']) {
    final error = array(policy[key], _schemaPath, '/$key');
    if (error != null) return error;
  }
  final projects = policy['projects'] as List;
  for (var i = 0; i < projects.length; i++) {
    final p = projects[i];
    final pointer = '/projects/$i';
    if (p is! Map) return pointer;
    final adapter = p['adapter'];
    if (adapter != 'dart') return '$pointer/adapter';
    final error = fields(p, ['id', 'adapter', 'package_roots'], [], pointer);
    if (error != null) return error;
    if (!_identifier(p['id'])) return '$pointer/id';
    final rootsError = array(
      p['package_roots'],
      _schemaPath,
      '$pointer/package_roots',
      nonempty: true,
    );
    if (rootsError != null) return rootsError;
  }
  final nodes = policy['nodes'] as List;
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    final pointer = '/nodes/$i';
    final error = fields(
      n,
      ['id', 'responsibility', 'owns', 'allows', 'public'],
      ['contracts'],
      pointer,
    );
    if (error != null) return error;
    if (!_identifier(n['id'])) return '$pointer/id';
    if (n['responsibility'] is! String ||
        (n['responsibility'] as String).isEmpty)
      return '$pointer/responsibility';
    for (final key in [
      'owns',
      'public',
      'allows',
      if (n.containsKey('contracts')) 'contracts',
    ]) {
      final error = array(
        n[key],
        key == 'allows'
            ? _identifier
            : key == 'contracts'
            ? (v) => v is String && v.isNotEmpty
            : _schemaPath,
        '$pointer/$key',
      );
      if (error != null) return error;
    }
  }
  return null;
}

String _pointerKey(String key) =>
    key.replaceAll('~', '~0').replaceAll('/', '~1');
