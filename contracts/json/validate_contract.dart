import '../../tool/validation/json_values.dart';

/// Structural JSON Schema validation and these semantic invariants are separate.
/// This finite specification does not execute Archway or certify compilers.
void invariants(Map result) {
  final p = result['payload'];
  final command = result['command'];
  if (p is! Map) return;
  if (command == 'node') {
    if (p['mode'] != 'catalogue' && p['node'] != null) {
      _sortedUnique(p['node']['public'], 'unique sorted normalized public');
    }
    if (p['mode'] == 'catalogue') {
      _require(
        p['total'] == (p['nodes'] as List).length + p['omitted'],
        'total = returned + omitted',
      );
      _sortedUnique([
        for (final node in p['nodes']) node['id'],
      ], 'unique sorted catalogue');
    }
    if (p['mode'] == 'path') {
      _require(
        (p['node'] != null) == (p['ownership']['ownership'] == 'owned'),
        'node presence follows ownership',
      );
    }
  }
  if (command == 'allows') {
    final same = p['mode'] == 'ids'
        ? p['from_id'] == p['to_id']
        : p['from']['owner_id'] != null &&
              p['from']['owner_id'] == p['to']['owner_id'];
    if (same)
      _require(p['policy_decision'] == 'allowed', 'same owner is allowed');
    _require(
      (p['reason'] == 'same_owner') == same,
      'same_owner reason exactly matches ownership',
    );
  }
  if (command == 'init') {
    final created = (p['created_paths'] as List).toSet();
    _require(
      created.containsAll(p['residual_paths']),
      'residual subset of created',
    );
    _require(
      created.intersection((p['conflicting_paths'] as List).toSet()).isEmpty,
      'never create existing target',
    );
    _require(
      p['dry_run'] != true ||
          sameJson([
            for (final file in p['planned_files']) file['path'],
          ], p['planned_paths']),
      'dry-run contains each planned file in order',
    );
  }
  if (command == 'check') {
    final observed = p['observed'];
    final coverage = p['coverage'];
    final files = coverage['files'] as List;
    final projects = coverage['projects'] as List;
    final edges = p['facts']['edges'] as List;
    _require(observed['files'] == files.length, 'corpus count');
    _require(
      observed['analyzed_files'] ==
          files
              .where(
                (file) => ['complete', 'partial'].contains(file['analysis']),
              )
              .length,
      'analyzed count',
    );
    _require(observed['edges'] == edges.length, 'edge count');
    for (final edge in edges) {
      final range = edge['source_range'];
      _require(
        _positionOrder(range['start'], range['end']) < 0,
        'nonempty edge span',
      );
      _require(range['path'] == edge['source'], 'edge range source match');
    }
    _require(
      observed['analyzed_files'] <= observed['files'],
      'analyzed <= corpus',
    );
    _require(p['projects'] == projects.length, 'project count');
    final known = {
      for (final project in projects)
        for (final context in project['contexts'])
          (project['project_id'], context['context_id']),
    };
    for (final file in files) {
      _require(
        (file['candidates'] as List).every(
          (candidate) => known.contains((
            candidate['project_id'],
            candidate['context_id'],
          )),
        ),
        'candidate descriptor exists',
      );
    }
    _require(
      edges.every(
        (edge) => known.contains((edge['project_id'], edge['context_id'])),
      ),
      'edge descriptor exists',
    );
    final byPath = {for (final file in files) file['path']: file};
    for (final edge in edges) {
      _require(byPath.containsKey(edge['source']), 'edge source in corpus');
      _require(
        (byPath[edge['source']]['candidates'] as List).any(
          (candidate) => sameJson(candidate, {
            'project_id': edge['project_id'],
            'context_id': edge['context_id'],
          }),
        ),
        'fact context must be source candidate',
      );
    }
    if (p['policy_valid'] == true) {
      _require(
        (p['input_identity']['inputs'] as List).any(
          (input) =>
              input['kind'] == 'policy' &&
              input['presence'] == 'present' &&
              input['hash'] == result['policy_hash'],
        ),
        'valid policy evidence matches envelope hash',
      );
    }
    for (final file in files) {
      if (file['assignment'] == 'assigned') {
        _require(
          sameJson(file['candidates'], [
            {
              'project_id': file['project_id'],
              'context_id': file['context_id'],
            },
          ]),
          'selected candidate',
        );
      }
    }
    if (p['analysis_complete'] == true) {
      _require(
        files.every(
          (file) =>
              file['assignment'] == 'assigned' &&
              file['analysis'] == 'complete',
        ),
        'complete file coverage',
      );
      _require(
        projects.every((project) => project['status'] == 'complete'),
        'complete projects',
      );
      _require(
        p['input_identity']['rechecked'] == true &&
            (p['input_identity']['changed_inputs'] as List).isEmpty,
        'complete stable identity',
      );
    }
    if (result['status'] == 'incomplete') {
      _require(
        (p['unknowns'] as List).isNotEmpty ||
            (p['tool_errors'] as List).isNotEmpty,
        'incomplete requires reason',
      );
    }
    _require(
      (p['warnings'] as List).every((d) => d['severity'] == 'warning'),
      'warning severity',
    );
    for (final key in ['violations', 'unknowns', 'tool_errors']) {
      _require(
        (p[key] as List).every((d) => d['severity'] == 'error'),
        'error severity',
      );
    }
  }
  _visitRanges(result);
}

int _positionOrder(Map start, Map end) {
  final line = (start['line'] as num).compareTo(end['line'] as num);
  return line != 0
      ? line
      : (start['column'] as num).compareTo(end['column'] as num);
}

void _visitRanges(Object? value) {
  if (value is Map) {
    if (value.length == 3 &&
        value.keys.toSet().containsAll(['path', 'start', 'end'])) {
      _require(
        _positionOrder(value['start'], value['end']) <= 0,
        'ordered source range',
      );
    }
    value.values.forEach(_visitRanges);
  } else if (value is List) {
    value.forEach(_visitRanges);
  }
}

void _sortedUnique(List values, String message) {
  final sorted = values.cast<String>().toSet().toList()..sort(compareUnicode);
  _require(sameJson(values, sorted), message);
}

void _require(bool valid, String message) {
  if (!valid) throw FormatException(message);
}

/// This self-contained export schema uses direct top-level definition references.
void verifyExportDefinitionReachability(Map schema) {
  final definitions = schema[r'$defs'] as Map;
  final reachable = <String>{};
  void visit(Object? value) {
    if (value is Map) {
      if (value.containsKey(r'$ref')) {
        final reference = value[r'$ref'] as String;
        const prefix = r'#/$defs/';
        _require(
          reference.startsWith(prefix),
          'export schema reference must be local',
        );
        final name = reference.substring(prefix.length);
        _require(
          definitions.containsKey(name),
          'export schema dangling reference: $reference',
        );
        if (reachable.add(name)) visit(definitions[name]);
      }
      for (final entry in value.entries) {
        if (entry.key != r'$defs') visit(entry.value);
      }
    } else if (value is List) {
      value.forEach(visit);
    }
  }

  visit(schema);
  final unused = definitions.keys.toSet().difference(reachable);
  _require(unused.isEmpty, 'export schema unreachable definitions: $unused');
}
