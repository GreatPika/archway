// Bind installer bytes and original logs to a verified native archive receipt.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart' show maxArchiveBytes;
import '../validation/json_schema.dart';
import '../validation/json_values.dart';
import 'release_execution_receipts.dart';
import 'release_installer_phases.dart';

/// Native acceptance (including prepared SDK identity/readiness) and source
/// validation remain caller prerequisites. [repository] owns contract schemas.
File validateInstaller(
  Map<String, dynamic> proof,
  Directory directory,
  String manifestSha256, {
  required Directory repository,
  required String version,
}) {
  final receipt = _object(proof['installer']);
  final target = proof['target'];
  final suffix = {
    'linux-x64': 'deb',
    'macos-arm64': 'pkg',
    'windows-x64': 'exe',
  }[target];
  if (suffix == null) _fail('Unsupported native installer target');
  final windows = target == 'windows-x64';
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  bool absolute(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      !value.contains('\u0000') &&
      paths.isAbsolute(value) &&
      (!windows || paths.rootPrefix(value).length > 1);
  final root = Directory(p.join(directory.path, 'installer'));
  final expected = 'archway-$version-$target-unsigned.$suffix';
  final artifact = _object(receipt['artifact']);
  final file = File(p.join(root.path, expected));
  final bytes = readOrdinaryBytes(file, limit: maxArchiveBytes);
  if (artifact['name'] != expected ||
      artifact['size'] is! int ||
      artifact['size'] != bytes.length ||
      artifact['sha256'] != sha256.convert(bytes).toString() ||
      receipt['bundle_manifest_sha256'] != manifestSha256) {
    _fail('Native installer artifact or input manifest differs');
  }
  if (!sameJson(receipt['cases'], [
    'install-old',
    'upgrade-final',
    'installed-command',
    'remove',
    'foreign-preserved',
    if (windows) ...[
      'raw-path-registry-types',
      'preexisting-path-token',
      'foreign-root-refusal',
      'foreign-command-refusal',
      'duplicate-token-refusal',
      'root-junction-refusal',
      'locked-stale-file-failure',
      'obsolete-directory-junction-uninstall',
    ],
  ])) {
    _fail('Native installer lifecycle cases are incomplete');
  }
  final old = _object(receipt['old_fixture']);
  if (old['version'] != '0.0.0' ||
      old['test_only'] != true ||
      old['removed_file'] != 'obsolete/installer-probe..txt') {
    _fail('Native installer lacks a distinct test-only old generation');
  }
  final compiler = _object(receipt['compiler']);
  final compilerName = {
    'linux-x64': 'dpkg-deb',
    'macos-arm64': 'pkgbuild',
    'windows-x64': 'ISCC.exe',
  }[target];
  if (!absolute(compiler['path']) ||
      paths.basename(compiler['path'] as String) != compilerName ||
      compiler['version'] is! String ||
      (compiler['version'] as String).trim().isEmpty) {
    _fail('Native installer compiler identity is missing');
  }
  for (final digest in [
    compiler['sha256'],
    old['manifest_sha256'],
    old['artifact_sha256'],
  ]) {
    if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))
      _fail('Native installer compiler/fixture hash is invalid');
  }
  final seen = <String>{};
  Map<String, List<int>> streams(Object? value) {
    final command = _object(value), argv = command['arguments'];
    const fields = {
      'arguments',
      'exit',
      'stdout',
      'stderr',
      'stdout_sha256',
      'stderr_sha256',
    };
    if (command.length != fields.length ||
        !fields.every(command.containsKey) ||
        argv is! List ||
        argv.isEmpty ||
        argv.any((a) => a is! String) ||
        command['exit'] is! int)
      _fail('Native installer command record is invalid');
    final data = <String, List<int>>{};
    for (final stream in ['stdout', 'stderr']) {
      final name = command[stream];
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9_.-]+\.log$').hasMatch(name) ||
          !seen.add(name)) {
        _fail('Native installer log name is invalid or reused');
      }
      data[stream] = verifiedBytes(
        File(p.join(root.path, name)),
        command['${stream}_sha256'],
      );
    }
    return data;
  }

  final commands = _list(receipt['commands']);
  if (commands.isEmpty)
    _fail('Native installer build/lifecycle logs are missing');
  for (final command in commands) {
    streams(command);
    if (target == 'linux-x64' && _object(command)['exit'] != 0)
      _fail('Native installer lifecycle command failed');
  }
  final installed = _object(receipt['installed']);
  if (windows && !absolute(installed['installation_root'])) {
    _fail('Native installed Windows root is missing or invalid');
  }
  validateInstallerPhases(proof, root, paths, version: version);
  if (installed['manifest_sha256'] != manifestSha256 ||
      !sameJson(installed['native_commands'], [
        'help',
        'version',
        'init',
        'validate',
        'export',
      ]) ||
      !sameJson(
        _list(installed['typescript'])
            .map((c) => [_object(c)['case'], _object(c)['exit']])
            .toList(),
        [
          ['clean', 0],
          ['dependency-violation', 1],
          ['unsupported-option', 64],
        ],
      ) ||
      !sameJson(installed['runtime_controls'], [
        for (final name in ['missing-node', 'wrong-node'])
          {
            'case': name,
            'exit': 2,
            'errors': ['NODE_UNAVAILABLE'],
          },
      ]))
    _fail('Native installed command coverage is incomplete');
  final processes = _list(installed['processes']);
  if (processes.length != 10 || !absolute(installed['binary']))
    _fail('Native installed command process inventory differs');
  const exits = [0, 0, 0, 0, 0, 0, 1, 64, 2, 2];
  const operations = [
    '--help',
    '--version',
    'init',
    'validate',
    'export',
    'check',
    'check',
    'check',
    'check',
    'check',
  ];
  final schemas = {
    for (final name in ['public-result', 'export-diagnostics'])
      name: ContractSchema(
        readRecord(
          File(p.join(repository.path, 'contracts/json/$name.schema.json')),
        ),
      ),
  };
  for (var index = 0; index < processes.length; index++) {
    final process = _object(processes[index]);
    final data = streams(process);
    final argv = process['arguments'] as List;
    final code = exits[index], command = operations[index];
    if (process['exit'] != code ||
        argv[0] != installed['binary'] ||
        (index < 2
            ? !sameJson(argv.sublist(1), [command])
            : argv.length < 4 || argv[1] != '--root' || argv[3] != command)) {
      _fail('Native installed process command/exit differs');
    }
    final stdout = utf8.decode(data['stdout']!),
        stderr = utf8.decode(data['stderr']!);
    bool valid;
    if (index == 0) {
      valid = stdout.startsWith('archway [--root ROOT]') && stderr.isEmpty;
    } else if (index == 1) {
      valid =
          ['archway $version\n', 'archway $version\r\n'].contains(stdout) &&
          stderr.isEmpty;
    } else {
      final value = _object(decodeEvidenceJson(index == 4 ? stderr : stdout));
      final schema =
          schemas[index == 4 ? 'export-diagnostics' : 'public-result']!;
      valid =
          value['exit_code'] is int &&
          value['exit_code'] == code &&
          (index == 4
              ? stdout.endsWith('flowchart LR\n')
              : value['command'] == command && stderr.isEmpty) &&
          schema.errors(value).isEmpty &&
          value['status'] ==
              {
                0: 'ok',
                1: 'negative',
                64: 'usage_error',
                2: 'incomplete',
              }[code];
      final payload = value['payload'];
      if (index == 2) {
        valid =
            valid &&
            payload is Map &&
            payload['outcome'] == 'created' &&
            payload['template'] == 'mixed';
      } else if (index == 3) {
        valid =
            valid &&
            sameJson(payload, {
              'policy_valid': true,
              'projects': 0,
              'nodes': 0,
            });
      } else if (index == 4) {
        valid = valid && sameJson(payload, {'format': 'mermaid', 'out': null});
      } else if (index == 7) {
        valid = valid && payload == null;
      } else {
        valid =
            valid &&
            payload is Map &&
            payload['policy_valid'] == true &&
            payload['analysis_complete'] == (code != 2);
        if (index >= 8)
          valid =
              valid &&
              sameJson(
                _list(_object(payload)['tool_errors'])
                    .map((e) => _object(e)['code'])
                    .toList(),
                ['NODE_UNAVAILABLE'],
              );
      }
    }
    if (!valid) _fail('Native installed original command output differs');
  }
  final suites = _list(installed['suites']);
  if (!sameJson(suites.map((s) => _object(s)['suite']).toList(), [
    'plan_query',
    'dart_check',
  ]))
    _fail('Installed query/Dart suite coverage differs');
  final acceptance = _object(proof['acceptance']);
  final sdk = _object(_object(acceptance['fixtures'])['manifest'])['dart_sdk'];
  for (final suite in suites) {
    final name = _object(suite)['suite'] as String;
    validateExecution(
      suite,
      [
        paths.join(sdk as String, 'bin', windows ? 'dart.exe' : 'dart'),
        '--suppress-analytics',
        'run',
        paths.join(
          acceptance['source_root'] as String,
          'test',
          '${name}_process_smoke.dart',
        ),
        installed['binary'] as String,
        if (name == 'dart_check') ...[
          sdk,
          acceptance['node_path'] as String,
          '--existing-installation',
        ],
      ],
      Directory(p.join(root.path, 'suites')),
      paths,
      suite: name,
    );
  }
  return file;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>)
    _fail('Native installer receipt object is missing or invalid');
  return value;
}

List<dynamic> _list(Object? value) {
  if (value is! List)
    _fail('Native installer receipt list is missing or invalid');
  return value;
}

Never _fail(String message) => throw FormatException(message);
