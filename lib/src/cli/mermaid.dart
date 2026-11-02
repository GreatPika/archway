import '../plan/plan.dart';

String formatMermaid(Plan plan, String hash) {
  final nodes = plan.declaredProjection();
  final ids = {for (var i = 0; i < nodes.length; i++) nodes[i].id: 'n$i'};
  final text = StringBuffer(
    '%% Declared policy permissions\n%% Policy hash: $hash\nflowchart LR\n',
  );
  for (final node in nodes) {
    text.writeln(
      '  ${ids[node.id]}["${_mermaidLabel(node.id)}: ${_mermaidLabel(node.responsibility)}"]',
    );
  }
  for (final node in nodes) {
    for (final target in node.allows) {
      text.writeln('  ${ids[node.id]} --> ${ids[target]}');
    }
  }
  return text.toString();
}

// Mermaid numeric entities keep every delimiter, control and Unicode rune out
// of the grammar. Encoding # and & also prevents user-supplied entities.
String _mermaidLabel(String value) => value.runes.map((rune) {
  final character = String.fromCharCode(rune);
  return RegExp(r'^[A-Za-z0-9 ._-]$').hasMatch(character)
      ? character
      : '#$rune;';
}).join();
