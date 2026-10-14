// Audit same-run exporter manifests and opaque tar hashes without extraction.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/installation_identity.dart';
import '../release/strict_json.dart';
import '../validation/json_values.dart';

void require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

const targets = {
  'linux-x64': ['Linux', 'x86_64'],
  'macos-arm64': ['Darwin', 'arm64'],
  'windows-x64': ['Windows', 'AMD64'],
};

// Preserve the existing report digest encoding: sorted JSON with ASCII escapes
// and a space after each separator (Python json.dumps defaults).
String digestJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort(compareUnicode);
    return '{${keys.map((key) => '${digestJson(key)}: ${digestJson(value[key])}').join(', ')}}';
  }
  if (value is List) return '[${value.map(digestJson).join(', ')}]';
  final encoded = jsonEncode(value);
  final output = StringBuffer();
  for (final unit in encoded.codeUnits) {
    output.write(
      unit >= 127
          ? '\\u${unit.toRadixString(16).padLeft(4, '0')}'
          : String.fromCharCode(unit),
    );
  }
  return output.toString();
}

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    final directories = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--expected-commit' || argument == '--report') {
        require(
          i + 1 < arguments.length && !options.containsKey(argument),
          'Missing or duplicate $argument',
        );
        options[argument] = arguments[++i];
      } else {
        require(!argument.startsWith('--'), 'Unknown option: $argument');
        directories.add(argument);
      }
    }
    require(
      options.length == 2 && directories.isNotEmpty,
      'Usage: audit_installation_transports.dart --expected-commit SHA --report FILE DIR...',
    );
    final source = await sourceIdentity(Directory.current);
    require(
      source['commit'] == options['--expected-commit'],
      'Checkout differs from expected workflow commit',
    );
    final audited = <String, Object?>{};
    Map<String, Object?>? shared;
    for (final directory in directories) {
      final record = decodeEvidenceJson(
        File(p.join(directory, 'provenance.json')).readAsStringSync(),
      ) as Map;
      require(
        sameJson(record['source'], source),
        'Manifest source differs from checked-out commit/tree/locks',
      );
      final target = record['target'];
      require(
        target is String &&
            targets.containsKey(target) &&
            !audited.containsKey(target),
        'Unknown or duplicate target',
      );
      require(
        record['schema_version'] is int && record['schema_version'] == 1,
        'Unsupported manifest schema',
      );
      final host = record['host'] as Map;
      final checks = record['checks'];
      final windows = target == 'windows-x64';
      require(
        host['system'] == targets[target]![0] &&
            host['machine'] == targets[target]![1] &&
            host['release'] is String &&
            (host['release'] as String).isNotEmpty &&
            sameJson(checks, {
              'profile': windows ? 'init-only' : 'process',
              'suites': windows
                  ? <String>[]
                  : [
                      'native_asset_process_smoke.dart',
                      'cli_process_smoke.dart',
                      'dart_check_process_smoke.dart',
                      'alias_trace_gap_process_smoke.dart',
                    ],
              'relocated_init': true,
              'transported_init': true,
            }),
        'Host or required check profile mismatch: $target',
      );
      final assets = <String, Object?>{};
      for (final item in (record['files'] as Map).entries) {
        final name = item.key as String;
        final entry = item.value as Map;
        require(
          name.isNotEmpty &&
              !p.posix.isAbsolute(name) &&
              // PurePosixPath also collapses empty and dot segments, but permits '.' itself.
              (name == '.' ||
                  name
                      .split('/')
                      .every((part) => part.isNotEmpty && part != '.')) &&
              !name.split('/').contains('..') &&
              !name.contains('\\') &&
              !name.contains(':') &&
              entry.length == 3 &&
              entry.keys.toSet().containsAll(['size', 'sha256', 'mode']) &&
              entry['size'] is int &&
              (entry['size'] as int) >= 0 &&
              entry['mode'] is int &&
              (entry['mode'] as int) >= 0 &&
              (entry['mode'] as int) <= 4095 &&
              entry['sha256'] is String &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['sha256'] as String),
          'Invalid file inventory: $target: $name',
        );
        if (name.startsWith('assets/'))
          assets[name] = {'size': entry['size'], 'sha256': entry['sha256']};
      }
      require(assets.isNotEmpty, 'Missing shared assets: $target');
      require(
        shared == null || sameJson(assets, shared),
        'Shared assets differ for $target',
      );
      shared = assets;
      final digest =
          (await sha256
                  .bind(File(p.join(directory, 'installation.tar')).openRead())
                  .first)
              .toString();
      require(
        sameJson(record['archive'], {
          'name': 'installation.tar',
          'sha256': digest,
        }),
        'Archive identity mismatch: $target',
      );
      audited[target as String] = {
        'archive_sha256': digest,
        'host': host,
        'checks': checks,
      };
    }
    require(audited.length == targets.length, 'Missing required target');
    final report = {
      'scope': 'transport-only; no extraction or package certification',
      'shared_asset_sha256': sha256
          .convert(utf8.encode(digestJson(shared)))
          .toString(),
      'source': source,
      'targets': audited,
    };
    File(options['--report']!).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln(jsonEncode(report));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
