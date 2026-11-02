import 'dart:convert';

class InputObservation {
  final String kind;
  final String observed;
  final String? canonical;
  final String? hash;
  final String role;
  final String? project;
  final List<Map<String, String>> symlinkHops;
  InputObservation(
    this.kind,
    this.observed,
    this.canonical,
    this.hash,
    this.role, [
    this.project,
    List<Map<String, String>> symlinkHops = const [],
  ]) : symlinkHops = List.unmodifiable(
         symlinkHops.map((hop) => Map<String, String>.unmodifiable(hop)),
       );
  String get contentIdentity => jsonEncode([kind, canonical, hash]);
  String get identity => jsonEncode([kind, canonical, hash, symlinkHops]);
}
