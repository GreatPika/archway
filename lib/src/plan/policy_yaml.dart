import 'package:yaml/yaml.dart';
// Pinned parser events preserve syntax that loadYaml intentionally discards.
import 'package:yaml/src/parser.dart';
import 'package:yaml/src/event.dart';
import 'package:yaml/src/scanner.dart';
import 'package:yaml/src/token.dart';

dynamic parsePolicyYaml(String source) {
  final text = _standardYamlTags(source);
  final parser = Parser(text);
  while (!parser.isDone) {
    final event = parser.parse();
    final forbidden = switch (event) {
      DocumentStartEvent(:final versionDirective, :final tagDirectives) =>
        tagDirectives.any((d) => d.prefix != 'tag:yaml.org,2002:') ||
            (versionDirective != null &&
                (versionDirective.major != 1 || versionDirective.minor != 2)),
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
        anchor != null || !{null, '!', 'tag:yaml.org,2002:seq'}.contains(tag),
      MappingStartEvent(:final anchor, :final tag) =>
        anchor != null || !{null, '!', 'tag:yaml.org,2002:map'}.contains(tag),
      _ => false,
    };
    if (forbidden)
      throw const FormatException(
        'Expected YAML 1.2 without aliases, anchors or custom tags.',
      );
  }
  final policy = loadYaml(text);
  _validateYamlValues(policy);
  return policy;
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
