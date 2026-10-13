import 'dart:convert';
import 'dart:io';

import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../../tool/validation/json_schema.dart';

final _requestSchema = _schema('request');
final _responseSchema = _schema('response');

ContractSchema _schema(String name) => ContractSchema(
  jsonDecode(File('contracts/helper/$name.schema.json').readAsStringSync()),
);

void _check(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

/// Independent contract-test oracle; not the package/helper implementation.
void validateHelper(Object? request, Object? response, {int exitCode = 0}) {
  _check(_requestSchema.errors(request).isEmpty, 'Invalid request schema');
  _check(_responseSchema.errors(response).isEmpty, 'Invalid response schema');
  _check(exitCode == 0, 'Nonzero exit invalidates envelope');
  final requestMap = request as Map;
  final responseMap = response as Map;
  _check(_uriOk(requestMap['root_uri']), 'Invalid root URI');
  for (final path in [
    requestMap['config_path'],
    ...requestMap['expected_files'],
  ]) {
    _check(_pathOk(path), 'Invalid repository path');
  }
  for (final key in ['protocol_version', 'request_id', 'project_id']) {
    _check(requestMap[key] == responseMap[key], 'Request correlation $key');
  }
  final expected = requestMap['expected_files'] as List;
  final sorted = expected.cast<String>().toList()..sort(_compareCodePoints);
  _check(
    jsonEncode(expected) == jsonEncode(sorted),
    'Expected corpus must be sorted',
  );
  final paths = (responseMap['files'] as List)
      .map((file) => file['path'])
      .toList();
  _check(
    jsonEncode(paths) == jsonEncode(expected),
    'Exact sorted coverage required',
  );
  final inputs = <String, dynamic>{
    for (final input in responseMap['inputs']) input['id'] as String: input,
  };
  _check(inputs.length == responseMap['inputs'].length, 'Duplicate input id');
  final observations = <String, (Object?, Object?, Object?)>{};
  for (final input in inputs.values) {
    for (final hop in input['symlink_hops']) {
      _check(_hopUriOk(hop['observed_uri']), 'Invalid symlink URI');
      // Raw readlink text is not normalized as a repository path.
      _check(_scalarText(hop['target']), 'Invalid symlink target text');
    }
    // Hop disagreements are freshness evidence, not malformed structure.
    final signature = (input['kind'], input['canonical_uri'], input['sha256']);
    final observed = input['observed_uri'] as String;
    _check(
      !observations.containsKey(observed) ||
          observations[observed] == signature,
      'Conflicting observed input identity',
    );
    observations[observed] = signature;
    _check(
      _uriOk(observed) &&
          (input['canonical_uri'] == null || _uriOk(input['canonical_uri'])),
      'Invalid input URI',
    );
    _check(
      (input['canonical_uri'] == null) == (input['kind'] == 'absent'),
      'Physical identity required for existing inputs',
    );
  }
  final root = requestMap['root_uri'] as String;
  final prefix = root.endsWith('/') ? root : '$root/';
  _check(
    inputs.values.any(
          (input) =>
              input['kind'] == 'file' &&
              input['observed_uri'] ==
                  prefix + _quotePath(requestMap['config_path']),
        ) ||
        responseMap['status'] == 'failed',
    'Missing config provenance',
  );
  for (final file in responseMap['files']) {
    final member = file['membership'] == 'member';
    _check(
      file['membership'] != 'unknown' || file['coverage'] == 'failed',
      'Unknown membership coverage',
    );
    _check(
      (file['membership'] == 'nonmember') ==
          (file['coverage'] == 'not_applicable'),
      'Nonmember coverage mismatch',
    );
    _check(
      member || file['input_id'] == null,
      'Nonmember/unknown source input',
    );
    final input = inputs[file['input_id']];
    if (member && file['coverage'] != 'failed') {
      _check(
        input != null && input['kind'] == 'file',
        'Missing source provenance',
      );
    }
    if (file['input_id'] != null) {
      _check(
        input != null &&
            input['observed_uri'] == prefix + _quotePath(file['path']),
        'Source identity mismatch',
      );
      _check(
        input['canonical_uri'] == input['observed_uri'],
        'Corpus source canonical alias/outside root',
      );
    }
  }
  for (final fact in responseMap['facts']) {
    _check(paths.contains(fact['source']), 'Unexpected source');
    final resolution = fact['resolution'];
    final evidence = fact['input_ids'] as List;
    if (resolution['kind'] == 'local') {
      final target = resolution['canonical_file_uri'] as String;
      _check(_uriOk(target), 'Invalid target URI');
      _check(
        resolution['via_path'] == null || _uriOk(resolution['via_path']),
        'Invalid alias URI',
      );
      final path = resolution['path'];
      _check(path == null || _pathOk(path), 'Invalid target path');
      _check(
        path != null
            ? target == prefix + _quotePath(path)
            : !target.startsWith(prefix),
        path != null
            ? 'Target repository path/URI mismatch'
            : 'In-root target requires repository path',
      );
      _check(
        inputs.values.any(
          (input) =>
              input['kind'] == 'file' &&
              input['canonical_uri'] == target &&
              evidence.contains(input['id']),
        ),
        'Missing local target provenance',
      );
    }
    _check(
      fact['source_range']['path'] == fact['source'],
      'Range source mismatch',
    );
    _check(evidence.every(inputs.containsKey), 'Dangling input reference');
    final source = responseMap['files'][paths.indexOf(fact['source'])];
    _check(
      source['membership'] == 'member' &&
          !['failed', 'not_applicable'].contains(source['coverage']) &&
          evidence.contains(source['input_id']),
      'Fact from unverified source',
    );
  }
  for (final item in [
    ...responseMap['facts'],
    ...responseMap['unknowns'],
    ...responseMap['tool_errors'],
  ]) {
    final range = item['source_range'];
    if (range == null) continue;
    final start = range['start'];
    final end = range['end'];
    final order = (start['line'] as num).compareTo(end['line'] as num);
    final columns = (start['column'] as num).compareTo(end['column'] as num);
    _check(
      order < 0 ||
          (order == 0 &&
              (item.containsKey('specifier') ? columns < 0 : columns <= 0)),
      'Empty edge or reversed range',
    );
    if (item.containsKey('path')) {
      _check(item['path'] == range['path'], 'Diagnostic span mismatch');
    }
  }
  if (responseMap['status'] == 'complete') {
    _check(
      (responseMap['files'] as List).every(
        (file) =>
            (file['membership'] == 'member' &&
                file['coverage'] == 'complete') ||
            file['membership'] == 'nonmember',
      ),
      'Incomplete coverage',
    );
    _check(
      responseMap['unknowns'].isEmpty && responseMap['tool_errors'].isEmpty,
      'Complete with diagnostics',
    );
    _check(
      (responseMap['facts'] as List).every(
        (fact) => fact['resolution']['kind'] != 'unresolved',
      ),
      'Unresolved marked complete',
    );
  }
  if (responseMap['status'] == 'incomplete') {
    _check(
      responseMap['unknowns'].isNotEmpty ||
          responseMap['tool_errors'].isNotEmpty,
      'Missing incomplete explanation',
    );
  }
  if (responseMap['status'] == 'failed') {
    _check(
      responseMap['tool_errors'].isNotEmpty,
      'Missing failure explanation',
    );
  }
}

bool _pathOk(String path) =>
    path == unicode.nfc(path) &&
    !path.startsWith('/') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
    !path.contains(r'\') &&
    !path.contains('\x00') &&
    path.split('/').every((part) => !['', '.', '..'].contains(part));

int _compareCodePoints(String left, String right) {
  final a = left.runes.iterator;
  final b = right.runes.iterator;
  while (a.moveNext()) {
    if (!b.moveNext()) return 1;
    final order = a.current.compareTo(b.current);
    if (order != 0) return order;
  }
  return b.moveNext() ? -1 : 0;
}

String _quotePath(String path, {bool keepColon = false}) {
  _check(_scalarText(path), 'Invalid path scalar text');
  var encoded = path.split('/').map(Uri.encodeComponent).join('/');
  for (final character in "!'()*".split('')) {
    encoded = encoded.replaceAll(
      character,
      '%${character.codeUnitAt(0).toRadixString(16).toUpperCase()}',
    );
  }
  return keepColon ? encoded.replaceAll('%3A', ':') : encoded;
}

bool _uriOk(String uri) =>
    uri.startsWith('file:///') &&
    !uri.contains('?') &&
    !uri.contains('#') &&
    !uri.contains('\x00') &&
    !RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(uri) &&
    !uri.contains('%00');

bool _scalarText(String value) =>
    !value.runes.any((point) => point >= 0xd800 && point <= 0xdfff);

bool _hopUriOk(String uri) {
  if (!_uriOk(uri) || RegExp(r'\s').hasMatch(uri)) return false;
  final encodedPath = uri.substring('file://'.length);
  // Decode without parsing/normalizing dot segments or percent escapes first.
  final path = Uri.decodeComponent(encodedPath);
  return _scalarText(path) &&
      !path.endsWith('/') &&
      path
          .split('/')
          .skip(1)
          .every((part) => !['', '.', '..'].contains(part)) &&
      _quotePath(path, keepColon: true) == encodedPath;
}

/// Modeled raw-byte/deadline boundaries, without launching an OS process.
void validateTransport({
  required int requestBytes,
  required int stdoutBytes,
  required int stderrBytes,
  required num elapsedSeconds,
  required int exitCode,
  required bool eof,
}) {
  _check(
    requestBytes <= 8 * 1048576 &&
        stdoutBytes <= 64 * 1048576 &&
        stderrBytes <= 256 * 1024,
    'Transport size exceeded',
  );
  _check(elapsedSeconds <= 120 && exitCode == 0 && eof, 'Transport invalid');
}

/// Strict UTF-8/JSON framing, including duplicate keys at every object depth.
Object? decodeEnvelope(List<int> bytes) {
  _check(
    bytes.length < 3 ||
        bytes[0] != 0xef ||
        bytes[1] != 0xbb ||
        bytes[2] != 0xbf,
    'JSON byte order mark',
  );
  final source = utf8.decode(bytes, allowMalformed: false);
  final decoded = jsonDecode(source);
  // The SDK validates JSON syntax and decodes values. This token walk only
  // checks duplicate names, which jsonDecode otherwise silently overwrites.
  final objects = <Set<String>?>[];
  final tokens = RegExp(r'"(?:[^"\\]|\\.)*"|[{}\[\]]');
  for (final token in tokens.allMatches(source)) {
    final text = token.group(0)!;
    if (text == '{') {
      objects.add(<String>{});
    } else if (text == '[') {
      objects.add(null);
    } else if (text == '}' || text == ']') {
      objects.removeLast();
    } else {
      var next = token.end;
      while (next < source.length && ' \t\r\n'.contains(source[next])) {
        next++;
      }
      if (next < source.length && source[next] == ':') {
        _check(
          objects.last!.add(jsonDecode(text) as String),
          'Duplicate object key',
        );
      }
    }
  }
  return decoded;
}
