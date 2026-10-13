import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;
// Pinned parser events preserve syntax that loadYaml intentionally discards.
import 'package:yaml/src/parser.dart';
import 'package:yaml/src/event.dart';
import 'package:yaml/src/scanner.dart';
import 'package:yaml/src/token.dart';

/// The canonical selected root and its lexical root-relative policy path.
class RepositorySelection {
  final String root;
  final String policyPath;
  const RepositorySelection(this.root, [this.policyPath = 'architecture.yaml']);
}

class Plan {
  int get projectCount => projects.length;
  final List<PlanProject> projects;
  int get nodeCount => nodes.length;
  final List<String> scope;
  final List<String> exclude;
  final List<PlanNode> nodes;
  Plan._(
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
    if (exclude.any((p) => _matches(p, path)))
      return Ownership(path, 'excluded', null);
    if (!scope.any((p) => _matches(p, path)))
      return Ownership(path, 'outside_scope', null);
    for (final node in nodes) {
      if (node.owns.any((p) => _matches(p, path)))
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

  static Future<PlanLoad> load(RepositorySelection selection) async {
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
      final text = _standardYamlTags(utf8.decode(bytes));
      final parser = Parser(text);
      while (!parser.isDone) {
        final event = parser.parse();
        final forbidden = switch (event) {
          DocumentStartEvent(:final versionDirective, :final tagDirectives) =>
            tagDirectives.any((d) => d.prefix != 'tag:yaml.org,2002:') ||
                (versionDirective != null &&
                    (versionDirective.major != 1 ||
                        versionDirective.minor != 2)),
          AliasEvent() => true,
          ScalarEvent(:final anchor, :final tag) =>
            anchor != null ||
                !{
                  null,
                  '!',
                  'tag:yaml.org,2002:str',
                  'tag:yaml.org,2002:int',
                  'tag:yaml.org,2002:float',
                  'tag:yaml.org,2002:bool',
                  'tag:yaml.org,2002:null',
                }.contains(tag),
          SequenceStartEvent(:final anchor, :final tag) =>
            anchor != null ||
                !{null, '!', 'tag:yaml.org,2002:seq'}.contains(tag),
          MappingStartEvent(:final anchor, :final tag) =>
            anchor != null ||
                !{null, '!', 'tag:yaml.org,2002:map'}.contains(tag),
          _ => false,
        };
        if (forbidden)
          throw const FormatException(
            'Expected YAML 1.2 without aliases, anchors or custom tags.',
          );
      }
      policy = loadYaml(text);
      _validateYamlValues(policy);
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
    const keys = ['version', 'projects', 'scope', 'exclude', 'nodes'];
    if (policy is! Map) {
      return invalid(
        'POLICY_SCHEMA_INVALID',
        'Expected a closed policy mapping.',
        '',
      );
    }
    for (final key in policy.keys) {
      if (!keys.contains(key))
        return invalid(
          'POLICY_SCHEMA_INVALID',
          'Unknown policy property.',
          '/${_pointerKey(key as String)}',
        );
    }
    for (final key in keys) {
      if (!policy.containsKey(key) ||
          (key == 'version' ? policy[key] is! int : policy[key] is! List)) {
        return invalid(
          'POLICY_SCHEMA_INVALID',
          'Missing or incorrectly typed $key.',
          '/$key',
        );
      }
    }
    if (policy['version'] != 1) {
      return invalid(
        'POLICY_VERSION_UNSUPPORTED',
        'Only policy version 1 is supported.',
        '/version',
      );
    }
    final shapeError = _validateShape(policy);
    if (shapeError != null) {
      return invalid(
        'POLICY_SCHEMA_INVALID',
        'Invalid policy value.',
        shapeError,
      );
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
            p['adapter'] == 'typescript'
                ? _policyPath(
                    p['tsconfig'],
                    '/projects/$i/tsconfig',
                    file: true,
                  )
                : null,
            p['adapter'] == 'dart'
                ? _policyPaths(
                    p['package_roots'],
                    '/projects/$i/package_roots',
                    directory: true,
                  )
                : [],
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
          (p) => owns.any((other) => other != p && _matches(other, p)),
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
      final plan = Plan._(
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
                  (p) => _matches(p, candidate) || _matches(candidate, p),
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
}

class PlanLoad {
  final String status;
  final String? policyHash;
  final Plan? plan;
  final List<PolicyDiagnostic> diagnostics;
  const PlanLoad(this.status, this.policyHash, this.plan, this.diagnostics);
}

class PolicyDiagnostic {
  final String code;
  final String severity;
  final String message;
  final String? rulePointer;
  final String? path;
  const PolicyDiagnostic(
    this.code,
    this.severity,
    this.message, [
    this.rulePointer,
    this.path,
  ]);
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
    if (adapter != 'dart' && adapter != 'typescript') return '$pointer/adapter';
    final error = fields(
      p,
      ['id', 'adapter', adapter == 'dart' ? 'package_roots' : 'tsconfig'],
      [],
      pointer,
    );
    if (error != null) return error;
    if (!_identifier(p['id'])) return '$pointer/id';
    if (adapter == 'dart') {
      final error = array(
        p['package_roots'],
        _schemaPath,
        '$pointer/package_roots',
        nonempty: true,
      );
      if (error != null) return error;
    } else if (!_schemaPath(p['tsconfig'])) {
      return '$pointer/tsconfig';
    }
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

void _validateYamlValues(dynamic value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String || entry.key == '<<') {
        throw const FormatException(
          'YAML keys must be strings; merge keys are unsupported.',
        );
      }
      _validateYamlValues(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _validateYamlValues(item);
    }
  } else if (value is num && !value.isFinite) {
    throw const FormatException('Non-finite YAML scalars are unsupported.');
  }
}

class Ownership {
  final String path;
  final String ownership;
  final String? ownerId;
  const Ownership(this.path, this.ownership, this.ownerId);
  Map<String, Object?> toJson() => {
    'path': path,
    'ownership': ownership,
    'owner_id': ownerId,
  };
}

class PlanNode {
  final String id;
  final String responsibility;
  final List<String> owns;
  final List<String> public;
  final List<String> allows;
  final List<String> contracts;
  final int policyIndex;
  PlanNode(
    this.id,
    this.responsibility,
    List<String> owns,
    List<String> public,
    List<String> allows,
    List<String> contracts,
    this.policyIndex,
  ) : owns = List.unmodifiable(owns),
      public = List.unmodifiable(public),
      allows = List.unmodifiable(allows),
      contracts = List.unmodifiable(contracts);
}

String normalizeRepositoryPath(
  String raw, {
  bool file = false,
  bool directory = false,
}) {
  final value = unicode.nfc(raw.replaceAll('\\', '/'));
  if (value.isEmpty ||
      value.startsWith('/') ||
      RegExp(r'[\x00-\x1f\x7f:*?"<>|\[\]{}]').hasMatch(value)) {
    throw const FormatException(
      'Expected a portable repository-relative path.',
    );
  }
  if (file &&
      (value.endsWith('/') || {'.', '..'}.contains(value.split('/').last))) {
    throw const FormatException('Expected an exact file path.');
  }
  final segments = <String>[];
  for (final part in value.split('/')) {
    if (part == '' || part == '.') continue;
    if (part == '..') {
      if (segments.isEmpty)
        throw const FormatException('Path escapes repository root.');
      segments.removeLast();
      continue;
    }
    if (part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw const FormatException('Path contains a nonportable component.');
    }
    segments.add(part);
  }
  if (segments.isEmpty) {
    if (file) throw const FormatException('Expected an exact file path.');
    return './';
  }
  return segments.join('/') + (directory || value.endsWith('/') ? '/' : '');
}

bool _matches(String pattern, String path) =>
    pattern == './' ||
    (pattern.endsWith('/') ? path.startsWith(pattern) : pattern == path);
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

class PlanProject {
  final String id;
  final String adapter;
  final String? tsconfig;
  final List<String> packageRoots;
  final int policyIndex;
  PlanProject(
    this.id,
    this.adapter,
    this.tsconfig,
    List<String> packageRoots,
    this.policyIndex,
  ) : packageRoots = List.unmodifiable(packageRoots);
}

List<String> _strings(List values) =>
    (values.cast<String>().toSet().toList()..sort(comparePlanText));

class PolicyDecision {
  final String decision;
  final String reason;
  const PolicyDecision(this.decision, this.reason);
}

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

String _pointerKey(String key) =>
    key.replaceAll('~', '~0').replaceAll('/', '~1');

/// Stable code-point ordering for normalized policy paths and text.
int comparePlanText(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (left.moveNext()) {
    if (!right.moveNext()) return 1;
    final difference = left.current.compareTo(right.current);
    if (difference != 0) return difference;
  }
  return right.moveNext() ? -1 : 0;
}

// Work around yaml 3.1.4's lost local suffixes and undefined verbatim handle.
// Normalize resolved core tag tokens only; scalar text and comments stay intact.
String _standardYamlTags(String text) {
  const prefix = 'tag:yaml.org,2002:';
  final core = {
    for (final name in ['str', 'int', 'float', 'bool', 'null', 'seq', 'map'])
      '$prefix$name',
  };
  final handles = {'!': '!', '!!': prefix};
  final declaredHandles = <String>{};
  final handleSyntax = RegExp(r'^!(?:!|[A-Za-z0-9-]+!)?$');
  final scanner = Scanner(text);
  var explicitFloat = false;
  final replacements = <(int, int, String)>[];
  for (
    var token = scanner.scan();
    token.type != TokenType.streamEnd;
    token = scanner.scan()
  ) {
    final current = token;
    if (current is ScalarToken &&
        explicitFloat &&
        RegExp(r'^[0-9]$').hasMatch(current.value)) {
      // Preserve the explicit float's type despite the loader's one-digit bug.
      final decimal = '${current.value}.0';
      final spelling = switch (current.style) {
        ScalarStyle.PLAIN => decimal,
        ScalarStyle.SINGLE_QUOTED => "'$decimal'",
        ScalarStyle.DOUBLE_QUOTED => '"$decimal"',
        _ => current.span.text.replaceFirstMapped(
          RegExp(r'^([ \t]*)[0-9]([ \t]*\r?)$', multiLine: true),
          (m) => '${m[1]}$decimal${m[2]}',
        ),
      };
      replacements.add((
        current.span.start.offset,
        current.span.end.offset,
        spelling,
      ));
    }
    if (current is! TagToken) explicitFloat = false;
    if (current is TagDirectiveToken) {
      if (!handleSyntax.hasMatch(current.handle))
        throw const FormatException('Invalid YAML tag handle.');
      if (!declaredHandles.add(current.handle))
        throw const FormatException('Duplicate YAML tag directive.');
      if (current.prefix.isEmpty ||
          !core.any((uri) => uri.startsWith(current.prefix)))
        throw const FormatException('Custom YAML tag directive.');
      handles[current.handle] = current.prefix;
      replacements.add((
        current.span.start.offset,
        current.span.end.offset,
        '%TAG ${current.handle} $prefix',
      ));
    } else if (current is TagToken) {
      final raw = current.span.text;
      final String uri;
      if (current.handle == '') {
        uri = current.suffix;
      } else if (current.handle == null) {
        uri = raw == '!'
            ? '!'
            : '${handles['!']}${Uri.decodeFull(raw.substring(1))}';
      } else {
        if (!handleSyntax.hasMatch(current.handle!) || current.suffix.isEmpty)
          throw const FormatException('Invalid YAML shorthand tag.');
        uri = '${handles[current.handle]}${current.suffix}';
      }
      explicitFloat = uri == '${prefix}float';
      if (uri != '!' && !core.contains(uri))
        throw const FormatException('Custom or undefined YAML tag.');
      replacements.add((
        current.span.start.offset,
        current.span.end.offset,
        uri == '!' ? '!' : '!!${uri.substring(prefix.length)}',
      ));
    }
  }
  for (final (start, end, tag) in replacements.reversed) {
    text = text.replaceRange(start, end, tag);
  }
  return text;
}
