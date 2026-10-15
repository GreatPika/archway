// Protocol-v2 alias evidence at the real CLI seam, using captured helper facts.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run test/alias_wire_process_smoke.dart <executable> <node>',
    );
    exitCode = 64;
    return;
  }
  final node = File(arguments[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-alias-wire-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final install = Directory(p.join(base.path, 'installation'))..createSync();
    final binary = stageInstallation(File(arguments[0]), install);
    final root = Directory(p.join(base.path, 'project'));
    File at(String name) => File(p.join(root.path, name));
    Directory(at('src/app').path).createSync(recursive: true);
    Directory(at('src/core').path).createSync();
    at('src/app/main.ts').writeAsStringSync("import '../core/private';");
    at('src/core/private.ts').writeAsStringSync('export {};');
    at('actual.json').writeAsStringSync(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
    );
    for (final entry in {
      'first.json': 'actual.json',
      'second.json': 'actual.json',
      'config.alias.json': 'first.json',
    }.entries) {
      Link(at(entry.key).path).createSync(entry.value);
    }
    at('tsconfig.json').writeAsStringSync(
      '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
    );
    const policy = '''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''';
    at('architecture.yaml').writeAsStringSync(policy);
    Future<Map<String, dynamic>> invoke(int expected) async {
      final result = await runNativeProcess(
        [binary.path, '--root', root.path, 'check'],
        timeout: const Duration(seconds: 15),
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': p.dirname(node)},
      );
      _check(result.exitCode == expected, 'Expected $expected: $result');
      _check(
        result.stderr.isEmpty &&
            result.stdout.where((b) => b == 10).length == 1,
        'Expected one JSON line and silent stderr: $result',
      );
      final value =
          jsonDecode(utf8.decode(result.stdout)) as Map<String, dynamic>;
      _check(
        schema.errors(value).isEmpty,
        'Invalid public schema: ${schema.errors(value)}',
      );
      count++;
      return value['payload'] as Map<String, dynamic>;
    }

    _check(
      (await invoke(1))['analysis_complete'] == true,
      'Baseline incomplete',
    );
    final helper = File(p.join(install.path, 'assets/typescript/helper.cjs'));
    final request = jsonEncode({
      'protocol_version': 2,
      'request_id': 'check:web',
      'project_id': 'web',
      'root_uri': File(root.path).uri.toString(),
      'config_path': 'tsconfig.json',
      'expected_files': ['src/app/main.ts', 'src/core/private.ts'],
    });
    // The wrapper only supplies stdin; the captured facts come from the genuine
    // installed helper and compiler. Both processes have bounded lifetimes.
    final capture = await runNativeProcess([
      node,
      '-e',
      '''
const r = require('node:child_process').spawnSync(process.execPath, [${jsonEncode(helper.path)}],
  {input: ${jsonEncode(request)}, timeout: 15000, maxBuffer: 64 * 1024 * 1024});
if (r.error) throw r.error;
process.stdout.write(r.stdout); process.stderr.write(r.stderr); process.exitCode = r.status ?? 1;
''',
    ], timeout: const Duration(seconds: 20));
    _check(capture.exitCode == 0, 'Genuine helper failed: $capture');
    final baseline =
        jsonDecode(utf8.decode(capture.stdout)) as Map<String, dynamic>;
    final aliasUri = at('config.alias.json').uri.toString();
    final aliasIndex = (baseline['inputs'] as List).indexWhere(
      (entry) => entry['observed_uri'] == aliasUri,
    );
    _check(
      aliasIndex >= 0 &&
          (baseline['inputs'][aliasIndex]['symlink_hops'] as List).length == 2,
      'Expected two captured alias hops',
    );
    Map<String, dynamic> copy() =>
        jsonDecode(jsonEncode(baseline)) as Map<String, dynamic>;
    void canned(Map<String, dynamic> value, [String extra = '']) {
      final encoded = base64Encode(utf8.encode(jsonEncode(value)));
      helper.writeAsStringSync(
        "let s='';process.stdin.on('data',b=>s+=b);process.stdin.on('end',()=>{const request=JSON.parse(s);const value=JSON.parse(Buffer.from('$encoded','base64'));$extra;process.stdout.write(JSON.stringify(value));});",
      );
    }

    Future<void> malformed(void Function(Map<String, dynamic>) edit) async {
      final value = copy();
      edit(value);
      canned(value);
      final report = await invoke(2);
      _check(
        (report['facts']['edges'] as List).isEmpty,
        'Malformed evidence retained edges',
      );
      _check(
        _has(report['tool_errors'], 'TYPESCRIPT_HELPER_FAILED'),
        'Missing helper failure: $report',
      );
    }

    await malformed((v) => v['protocol_version'] = 1);
    await malformed(
      (v) => (v['inputs'][aliasIndex] as Map).remove('symlink_hops'),
    );
    for (final hop in [
      {'observed_uri': 'file:///', 'target': 'first.json'},
      {'observed_uri': aliasUri, 'target': ''},
      {'observed_uri': aliasUri, 'target': 'bad\u0000name'},
      {'observed_uri': aliasUri, 'target': 'bad\ud800'},
      {'observed_uri': aliasUri, 'target': 'first.json', 'extra': true},
    ]) {
      await malformed((v) => v['inputs'][aliasIndex]['symlink_hops'] = [hop]);
    }
    await malformed((v) {
      final hops = v['inputs'][aliasIndex]['symlink_hops'] as List;
      v['inputs'][aliasIndex]['symlink_hops'] = [
        for (var i = 0; i < 21; i++) ...hops,
      ];
    });
    // Repeated completed hops may conflict within one otherwise valid witness.
    final conflict = copy();
    final conflicting = conflict['inputs'][aliasIndex];
    conflict['inputs'] = (conflict['inputs'] as List)
        .where(
          (entry) =>
              identical(entry, conflicting) ||
              !(entry['symlink_hops'] as List).any(
                (hop) => hop['observed_uri'] == aliasUri,
              ),
        )
        .toList();
    (conflicting['symlink_hops'] as List).add({
      'observed_uri': aliasUri,
      'target': 'second.json',
    });
    canned(conflict);
    var report = await invoke(2);
    _check(
      (report['facts']['edges'] as List).isEmpty &&
          (report['tool_errors'] as List).isEmpty,
      'Conflict classified as malformed or retained edges: $report',
    );
    _check(
      _has(report['unknowns'], 'INPUT_CHANGED'),
      'Missing conflict diagnostic',
    );
    for (final reverse in [false, true]) {
      final value = copy();
      for (final entry in value['inputs']) {
        entry['symlink_hops'] = reverse
            ? (entry['symlink_hops'] as List).reversed.toList()
            : [];
      }
      canned(value);
      report = await invoke(2);
      _check(
        _has(report['unknowns'], 'INPUT_CHANGED'),
        'Missing freshness diagnostic',
      );
      _check(
        (report['facts']['edges'] as List).isNotEmpty &&
            report['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
        'Freshness disagreement lost independent violation',
      );
      _check(
        (report['tool_errors'] as List).isEmpty,
        'Freshness disagreement became envelope failure',
      );
    }
    at('architecture.yaml').writeAsStringSync(
      policy.replaceFirst(
        'projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]',
        'projects: [{id: a, adapter: typescript, tsconfig: tsconfig.json}, {id: b, adapter: typescript, tsconfig: tsconfig.json}]',
      ),
    );
    canned(
      baseline,
      "value.request_id=request.request_id;value.project_id=request.project_id;if(request.project_id==='b'){for(const entry of value.inputs){for(const hop of entry.symlink_hops){if(hop.observed_uri.endsWith('/config.alias.json'))hop.target='second.json';}}}",
    );
    report = await invoke(2);
    _check(
      (report['facts']['edges'] as List).isEmpty &&
          (report['tool_errors'] as List).isEmpty,
      'Shared conflict must invalidate both suppliers without envelope errors',
    );
    _check(
      (report['coverage']['files'] as List).every(
        (f) =>
            f['discovery_complete'] == false &&
            sameJson(f['unresolved_project_ids'], ['a', 'b']),
      ),
      'Shared conflict file coverage: $report',
    );
    _check(
      (report['coverage']['projects'] as List).every(
        (project) => project['status'] == 'partial',
      ),
      'Shared conflict project coverage',
    );
    _check(
      _has(report['unknowns'], 'INPUT_CHANGED'),
      'Missing shared conflict diagnostic',
    );
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln('$count bounded alias-wire process checks passed');
}

bool _has(dynamic entries, String code) =>
    (entries as List).any((entry) => entry['code'] == code);
void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}
