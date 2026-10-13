part of 'inspection.dart';

/// Strict framing also rejects duplicate keys before dart:convert can erase them.
class _JsonFrame {
  final String text;
  var index = 0;
  _JsonFrame(List<int> bytes) : text = utf8.decode(bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      throw const FormatException('Helper JSON BOM is forbidden.');
    }
  }
  Never bad() => throw const FormatException('Invalid helper JSON frame.');
  void space() {
    while (index < text.length && ' \t\r\n'.contains(text[index])) {
      index++;
    }
  }

  Object? decode() {
    final result = value();
    space();
    if (index != text.length) bad();
    return result;
  }

  String string() {
    final start = index++;
    while (index < text.length) {
      final c = text[index++];
      if (c == '"') return jsonDecode(text.substring(start, index)) as String;
      if (c == '\\') index++;
    }
    bad();
  }

  Object? value([int depth = 0]) {
    if (depth > 128) bad();
    space();
    if (index >= text.length) bad();
    final c = text[index];
    if (c == '"') return string();
    if (c == '{') {
      index++;
      space();
      final map = <String, Object?>{};
      if (index < text.length && text[index] == '}') {
        index++;
        return map;
      }
      while (true) {
        space();
        if (index >= text.length || text[index] != '"') bad();
        final key = string();
        space();
        if (map.containsKey(key) ||
            index >= text.length ||
            text[index++] != ':')
          bad();
        map[key] = value(depth + 1);
        space();
        if (index >= text.length) bad();
        final end = text[index++];
        if (end == '}') return map;
        if (end != ',') bad();
      }
    }
    if (c == '[') {
      index++;
      space();
      final list = <Object?>[];
      if (index < text.length && text[index] == ']') {
        index++;
        return list;
      }
      while (true) {
        list.add(value(depth + 1));
        space();
        if (index >= text.length) bad();
        final end = text[index++];
        if (end == ']') return list;
        if (end != ',') bad();
      }
    }
    final start = index;
    while (index < text.length && !' \t\r\n,]}'.contains(text[index])) {
      index++;
    }
    if (index == start) bad();
    final result = jsonDecode(text.substring(start, index));
    if (result is double && !result.isFinite) bad();
    return result;
  }
}

void _require(bool ok, String message) {
  if (!ok) throw FormatException(message);
}

Map<String, dynamic> _object(dynamic value, List<String> keys) {
  _require(value is Map<String, dynamic>, 'Expected an object.');
  final map = value as Map<String, dynamic>;
  _require(
    map.length == keys.length && keys.every(map.containsKey),
    'Unexpected helper object properties.',
  );
  return map;
}

List<dynamic> _array(dynamic value) {
  _require(value is List, 'Expected an array.');
  return value as List;
}

String _text(dynamic value) {
  _require(value is String && value.isNotEmpty, 'Expected nonempty text.');
  return value as String;
}

String _helperPath(dynamic value) {
  final path = _text(value);
  _require(
    unicode.nfc(path) == path &&
        !path.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
        !path.contains('\\') &&
        !path.contains('\x00') &&
        path.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..'),
    'Invalid helper repository path.',
  );
  _require(
    normalizeRepositoryPath(path, file: true) == path,
    'Helper path is outside the portable repository profile.',
  );
  return path;
}

String _helperUri(dynamic value) {
  final uri = _text(value);
  final parsed = Uri.parse(uri);
  _require(
    parsed.scheme == 'file' &&
        parsed.authority.isEmpty &&
        parsed.path.startsWith('/') &&
        !parsed.hasQuery &&
        !parsed.hasFragment &&
        !uri.contains('\\') &&
        !parsed.path.contains('\x00') &&
        !RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(uri) &&
        _uri(p.normalize(PhysicalPaths.fromFileUri(parsed))) == uri,
    'Invalid canonical file URI.',
  );
  return uri;
}

Future<ProjectEvidence> _validateHelper(
  ProjectRequest request,
  List<int> bytes,
) async {
  final response = _object(_JsonFrame(bytes).decode(), [
    'protocol_version',
    'request_id',
    'project_id',
    'status',
    'files',
    'facts',
    'unknowns',
    'tool_errors',
    'inputs',
  ]);
  for (final key in ['protocol_version', 'request_id', 'project_id']) {
    _require(
      response[key] == _requestEnvelope(request)[key],
      'Helper correlation mismatch.',
    );
  }
  _require(
    {'complete', 'incomplete', 'failed'}.contains(response['status']),
    'Invalid helper status.',
  );
  final inputs = <String, Map<String, dynamic>>{};
  final observations = <_Observation>[];
  for (final raw in _array(response['inputs'])) {
    _require(raw is Map, 'Invalid helper input.');
    final item = _object(raw, [
      'id',
      'kind',
      'observed_uri',
      'canonical_uri',
      'symlink_hops',
      if (raw['kind'] != 'absent') 'sha256',
    ]);
    final id = _text(item['id']);
    _require(!inputs.containsKey(id), 'Duplicate input ID.');
    inputs[id] = item;
    final kind = item['kind'];
    _require(
      {'file', 'directory', 'absent'}.contains(kind),
      'Invalid input kind.',
    );
    final observed = _helperUri(item['observed_uri']);
    final canonical = kind == 'absent'
        ? null
        : _helperUri(item['canonical_uri']);
    _require(
      kind == 'directory' ||
          (observed != 'file:///' && canonical != 'file:///'),
      'Filesystem-root observations must be directories.',
    );
    _require(
      (item['canonical_uri'] == null) == (kind == 'absent'),
      'Input identity/presence mismatch.',
    );
    final hash = item['sha256'];
    _require(
      kind == 'absent' ||
          hash is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash),
      'Invalid input digest.',
    );
    final relative = _relative(
      request.selection.root,
      PhysicalPaths.fromFileUri(Uri.parse(observed)),
    );
    final role = relative == request.project.tsconfig!
        ? 'config'
        : request.expectedFiles.contains(relative)
        ? 'source'
        : 'resolution';
    final hops = <Map<String, String>>[];
    final rawHops = _array(item['symlink_hops']);
    _require(rawHops.length <= 40, 'Too many symlink hop witnesses.');
    for (final rawHop in rawHops) {
      final hop = _object(rawHop, ['observed_uri', 'target']);
      final uri = _helperUri(hop['observed_uri']);
      final target = _text(hop['target']);
      _require(
        uri != 'file:///' &&
            !target.contains('\x00') &&
            utf8.decode(utf8.encode('x$target')) == 'x$target',
        'Invalid symlink hop witness.',
      );
      hops.add({'observed_uri': uri, 'target': target});
    }
    observations.add(
      _Observation(
        kind,
        observed,
        canonical,
        hash,
        role,
        request.project.id,
        hops,
      ),
    );
  }
  _require(
    response['status'] == 'failed' ||
        observations.any(
          (i) =>
              i.kind == 'file' &&
              i.observed ==
                  _uri(
                    p.join(request.selection.root, request.project.tsconfig!),
                  ),
        ),
    'Missing configuration evidence.',
  );
  final files = <String, Map<String, dynamic>>{};
  final rows = _array(response['files']);
  _require(
    rows.length == request.expectedFiles.length,
    'Incomplete corpus response.',
  );
  for (var i = 0; i < rows.length; i++) {
    final row = _object(rows[i], [
      'path',
      'membership',
      'coverage',
      'input_id',
    ]);
    final file = _helperPath(row['path']);
    _require(
      file == request.expectedFiles[i],
      'Unexpected corpus response order.',
    );
    files[file] = row;
    _require(
      {'member', 'nonmember', 'unknown'}.contains(row['membership']) &&
          {
            'complete',
            'partial',
            'failed',
            'not_applicable',
          }.contains(row['coverage']),
      'Invalid membership/coverage.',
    );
    _require(
      (row['membership'] == 'nonmember') ==
          (row['coverage'] == 'not_applicable'),
      'Inconsistent membership/coverage.',
    );
    if (row['membership'] != 'member') {
      _require(
        row['input_id'] == null &&
            (row['membership'] != 'unknown' || row['coverage'] == 'failed'),
        'Unknown membership cannot supply source evidence.',
      );
    } else if (row['coverage'] != 'failed') {
      _require(row['input_id'] is String, 'Missing source evidence.');
    }
    if (row['input_id'] != null) {
      final input = inputs[row['input_id']];
      _require(
        input != null &&
            input['kind'] == 'file' &&
            input['observed_uri'] ==
                _uri(p.join(request.selection.root, file)) &&
            input['canonical_uri'] == input['observed_uri'],
        'Source identity mismatch.',
      );
    }
  }
  final sourceTexts = <String, String>{};
  Future<void> range(dynamic raw, String file, {required bool nonempty}) async {
    final span = _object(raw, ['path', 'start', 'end']);
    _require(_helperPath(span['path']) == file, 'Source range path mismatch.');
    final offsets = <int>[];
    var text = sourceTexts[file];
    if (text == null) {
      final sourceBytes = await File(p.join(request.selection.root, file))
          .readAsBytes();
      final input = inputs[files[file]?['input_id']];
      _require(
        input != null &&
            sha256.convert(sourceBytes).toString() == input['sha256'],
        'Cannot validate range against changed or missing source.',
      );
      text = sourceTexts[file] = utf8.decode(sourceBytes);
    }
    final lines = text.split(RegExp(r'\r\n|\r|\n|\u2028|\u2029'));
    for (final end in ['start', 'end']) {
      final pos = _object(span[end], ['line', 'column']);
      final line = pos['line'], column = pos['column'];
      _require(
        line is int &&
            column is int &&
            line >= 1 &&
            line <= lines.length &&
            column >= 1 &&
            column <= lines[line - 1].length + 1,
        'Source range is outside observed bytes.',
      );
      offsets.add(line);
      offsets.add(column);
    }
    final order = offsets[0].compareTo(offsets[2]);
    _require(
      order < 0 ||
          order == 0 &&
              (nonempty ? offsets[1] < offsets[3] : offsets[1] <= offsets[3]),
      'Empty or reversed source range.',
    );
  }

  final facts = <Map<String, dynamic>>[];
  for (final raw in _array(response['facts'])) {
    final fact = _object(raw, [
      'source',
      'source_range',
      'kind',
      'specifier',
      'type_only',
      'resolution',
      'input_ids',
    ]);
    final source = _helperPath(fact['source']);
    final row = files[source];
    _require(
      row != null &&
          row['membership'] == 'member' &&
          {'complete', 'partial'}.contains(row['coverage']),
      'Unverified fact source.',
    );
    _require(
      {
            'import',
            'export',
            'import_type',
            'require',
            'dynamic_import',
          }.contains(fact['kind']) &&
          fact['specifier'] is String &&
          fact['type_only'] is bool,
      'Invalid fact.',
    );
    final ids = _array(fact['input_ids']);
    _require(
      ids.isNotEmpty &&
          ids.toSet().length == ids.length &&
          ids.every((id) => id is String && inputs.containsKey(id)) &&
          ids.contains(row!['input_id']),
      'Dangling fact evidence.',
    );
    await range(fact['source_range'], source, nonempty: true);
    final resolution = fact['resolution'];
    _require(resolution is Map, 'Invalid target.');
    if (resolution['kind'] == 'local') {
      _object(resolution, ['kind', 'path', 'canonical_file_uri', 'via_path']);
      final target = _helperUri(resolution['canonical_file_uri']);
      final relative = _relative(
        request.selection.root,
        PhysicalPaths.fromFileUri(Uri.parse(target)),
      );
      _require(
        relative != './' && resolution['path'] == relative,
        'Target path/URI mismatch.',
      );
      if (relative != null) _helperPath(relative);
      if (resolution['via_path'] != null) {
        final via = _helperUri(resolution['via_path']);
        _require(
          via != target &&
              ids.any(
                (id) =>
                    inputs[id]!['kind'] == 'file' &&
                    inputs[id]!['observed_uri'] == via &&
                    inputs[id]!['canonical_uri'] == target,
              ),
          'Local target alias lacks direct matching provenance.',
        );
      }
      _require(
        ids.any(
          (id) =>
              inputs[id]!['kind'] == 'file' &&
              inputs[id]!['canonical_uri'] == target,
        ),
        'Missing target evidence.',
      );
    } else if (resolution['kind'] == 'external' ||
        resolution['kind'] == 'builtin') {
      _object(resolution, ['kind', 'identity']);
      final identity = _text(resolution['identity']);
      final builtin = resolution['kind'] == 'builtin';
      _require(
        builtin
            ? RegExp(r'^node:[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)?$')
                  .hasMatch(identity)
            : (identity.startsWith('npm:') || identity.startsWith('pnpm:')),
        'Unknown package identity.',
      );
      var matched = false;
      for (final id in ids) {
        final input = inputs[id]!;
        if (input['kind'] != 'file' ||
            !input['canonical_uri'].endsWith('/package.json'))
          continue;
        final file = File(
          PhysicalPaths.fromFileUri(Uri.parse(input['observed_uri'])),
        );
        List<int> bytes;
        try {
          bytes = await file.readAsBytes();
        } on FileSystemException {
          // A missing/unreadable post-observation manifest is rechecked below.
          matched = true;
          continue;
        }
        // A changed baseline belongs to input revalidation, not wire framing.
        if (sha256.convert(bytes).toString() != input['sha256']) {
          matched = true;
          continue;
        }
        final manifest = _JsonFrame(bytes).decode();
        if (manifest is! Map ||
            !(builtin && manifest['name'] == '@types/node' ||
                identity == 'npm:${manifest['name']}@${manifest['version']}' ||
                identity == 'pnpm:${manifest['name']}@${manifest['version']}' ||
                identity.startsWith(
                  'pnpm:${manifest['name']}@${manifest['version']}(',
                )))
          continue;
        final root = p.dirname(
          PhysicalPaths.fromFileUri(Uri.parse(input['canonical_uri'])),
        );
        matched = ids.any((other) {
          final target = inputs[other]!;
          return other != row!['input_id'] &&
              target['kind'] == 'file' &&
              target['canonical_uri'] != input['canonical_uri'] &&
              (!builtin || target['canonical_uri'].endsWith('.d.ts')) &&
              p.isWithin(
                root,
                PhysicalPaths.fromFileUri(Uri.parse(target['canonical_uri'])),
              );
        });
        if (matched) break;
      }
      _require(
        matched &&
            ids.any((id) {
              final input = inputs[id]!;
              return input['kind'] == 'file' &&
                  [
                    'package-lock.json',
                    'npm-shrinkwrap.json',
                    'pnpm-lock.yaml',
                  ].contains(
                    p.basename(
                      PhysicalPaths.fromFileUri(
                        Uri.parse(input['observed_uri']),
                      ),
                    ),
                  );
            }),
        'Missing package manifest, target or lock evidence.',
      );
    } else if (resolution['kind'] == 'unresolved') {
      _object(resolution, ['kind']);
    } else {
      // Package/SDK provenance is a later slice. Never accept an unproved category.
      throw const FormatException(
        'Unsupported target provenance classification.',
      );
    }
    facts.add(fact);
  }
  final diagnostics = <String, List<Map<String, dynamic>>>{};
  for (final category in ['unknowns', 'tool_errors']) {
    final values = <Map<String, dynamic>>[];
    for (final raw in _array(response[category])) {
      final diagnostic = _object(raw, [
        'code',
        'message',
        'path',
        'source_range',
      ]);
      _text(diagnostic['code']);
      _text(diagnostic['message']);
      if (diagnostic['path'] != null) _helperPath(diagnostic['path']);
      if (diagnostic['source_range'] != null) {
        await range(
          diagnostic['source_range'],
          _helperPath(diagnostic['path']),
          nonempty: false,
        );
      }
      values.add(diagnostic);
    }
    diagnostics[category] = values;
  }
  final unknowns = diagnostics['unknowns']!,
      errors = diagnostics['tool_errors']!;
  if (response['status'] == 'complete') {
    _require(
      unknowns.isEmpty &&
          errors.isEmpty &&
          rows.every(
            (f) =>
                f['membership'] == 'nonmember' ||
                f['membership'] == 'member' && f['coverage'] == 'complete',
          ) &&
          facts.every((f) => f['resolution']['kind'] != 'unresolved'),
      'False complete helper response.',
    );
  } else {
    _require(
      unknowns.isNotEmpty || errors.isNotEmpty,
      'Missing incomplete explanation.',
    );
    if (response['status'] == 'failed')
      _require(errors.isNotEmpty, 'Missing failure explanation.');
  }
  _require(
    !facts.any((f) => f['resolution']['kind'] == 'unresolved') ||
        unknowns.isNotEmpty,
    'Unresolved fact lacks uncertainty.',
  );
  return ProjectEvidence(
    request,
    response['status'],
    rows.any((f) => f['membership'] != 'unknown') ||
            (rows.isEmpty && response['status'] != 'failed')
        ? [
            {
              'context_id': 'typescript:${request.project.id}',
              'descriptor': {'tsconfig': request.project.tsconfig},
            },
          ]
        : [],
    files,
    facts,
    observations,
    unknowns,
    errors,
  );
}
