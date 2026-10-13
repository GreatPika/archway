import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../bootstrap/bootstrap.dart';
import '../plan/plan.dart';
import '../inspection/inspection.dart';
import '../native/native_io.dart';
import '../native/physical_paths.dart';

part 'export_file.dart';

const archwayVersion = '0.1.0';

class CliStreams {
  final StringSink stdout;
  final StringSink stderr;
  const CliStreams(this.stdout, this.stderr);
}

/// Owns invocation grammar, transport, and composition. It never exits the VM.
class CLI {
  final Future<void>? cancelled;
  CLI({this.cancelled});
  Future<int> run(List<String> args, CliStreams streams) async {
    if (args.length == 1 && args.single == '--version') {
      streams.stdout.writeln('archway $archwayVersion');
      return 0;
    }
    if ((args.length == 1 && args.single == '--help') ||
        (args.length == 2 &&
            _Invocation.commands.contains(args.first) &&
            args.last == '--help')) {
      final command = args.length == 2 ? args.first : null;
      streams.stdout.writeln(_help(command));
      return 0;
    }
    final invocation = _Invocation();
    try {
      invocation.parse(args);
    } on FormatException catch (error) {
      return _usage(
        streams,
        invocation.command,
        error.message,
        exportPayload: invocation.exportPayload,
      );
    }
    final options = invocation.options;
    final command = invocation.command;
    final String root;
    try {
      root = await PhysicalPaths.canonical(
        options['--root'] ?? Directory.current.path,
      );
      if (!await Directory(root).exists()) {
        return _usage(
          streams,
          command,
          '--root must select an existing directory.',
          exportPayload: invocation.exportPayload,
        );
      }
    } on FileSystemException catch (error) {
      // Win32 FILE_NOT_FOUND / PATH_NOT_FOUND / DIRECTORY; POSIX ENOENT /
      // ENOTDIR. Win32 20 is BAD_UNIT, an operational error, not ENOTDIR.
      final invalidRootCodes = Platform.isWindows ? {2, 3, 267} : {2, 20};
      if (invalidRootCodes.contains(error.osError?.errorCode)) {
        return _usage(
          streams,
          command,
          '--root must select an existing directory.',
          exportPayload: invocation.exportPayload,
        );
      }
      return _failure(
        streams,
        command,
        'ROOT_ACCESS_FAILED',
        error.toString(),
        exportPayload: invocation.exportPayload,
      );
    }
    String? mermaid;
    Object? payload;
    String? policyPath;
    String? policyHash;
    var status = 'ok';
    var exitCode = 0;
    var diagnostics = <Map<String, Object?>>[];
    var inspectionVersions = <String, Object?>{};
    if (command == 'check') {
      policyPath = options['--policy'] ?? 'architecture.yaml';
      final report = await Inspection(cancelled: cancelled)
          .check(RepositorySelection(root, policyPath));
      policyHash = report.policyHash;
      status = report.status;
      exitCode = report.exitCode;
      diagnostics = report.diagnostics;
      payload = report.payload;
      inspectionVersions = report.toolVersions;
    } else if (command != 'init') {
      policyPath = path.posix.normalize(
        (options['--policy'] ?? 'architecture.yaml').replaceAll('\\', '/'),
      );
      final loaded = await Plan.load(RepositorySelection(root, policyPath));
      policyHash = loaded.policyHash;
      status = loaded.status;
      exitCode = status == 'ok' ? 0 : 2;
      diagnostics = loaded.diagnostics
          .map(
            (d) => _diagnostic(
              d.code,
              d.severity,
              d.message,
              pointer: d.rulePointer,
              path: d.path,
            ),
          )
          .toList();
      final plan = loaded.plan;
      if (plan != null) {
        if (command == 'export') {
          mermaid = _mermaid(plan, policyHash!);
        } else if (command == 'validate') {
          payload = {
            'policy_valid': true,
            'projects': plan.projectCount,
            'nodes': plan.nodeCount,
          };
        } else if (command == 'owner') {
          final owner = plan.owner(invocation.operands.single);
          payload = owner.toJson();
          if (owner.ownerId == null) {
            status = 'negative';
            exitCode = 1;
          }
        } else if (command == 'allows') {
          final from = invocation.operands[0];
          final to = invocation.operands[1];
          final paths = options.containsKey('--paths');
          final unknown = paths
              ? null
              : [from, to].where((id) => plan.node(id) == null).firstOrNull;
          if (unknown != null) {
            status = 'error';
            exitCode = 2;
            diagnostics.add(
              _diagnostic(
                'UNKNOWN_NODE_ID',
                'error',
                'Unknown node ID: $unknown.',
              ),
            );
          } else {
            final decision = paths
                ? plan.allowsPaths(from, to)
                : plan.allows(from, to);
            payload = {
              'mode': paths ? 'paths' : 'ids',
              'policy_only': true,
              'decision_scope': paths ? 'file' : 'module',
              if (paths) 'from': plan.owner(from).toJson() else 'from_id': from,
              if (paths) 'to': plan.owner(to).toJson() else 'to_id': to,
              'policy_decision': decision.decision,
              'reason': decision.reason,
            };
            if (decision.decision != 'allowed') {
              status = 'negative';
              exitCode = 1;
            }
          }
        } else if (command == 'node') {
          final targetPath = options['--path'];
          if (targetPath == null && invocation.operands.isEmpty) {
            payload = plan.catalogue(
              offset: int.parse(options['--offset'] ?? '0'),
              limit: options['--limit'] == null
                  ? null
                  : int.parse(options['--limit']!),
            );
          } else if (targetPath != null) {
            final owner = plan.owner(targetPath);
            payload = {
              'mode': 'path',
              'ownership': owner.toJson(),
              'node': owner.ownerId == null ? null : plan.node(owner.ownerId!),
            };
            if (owner.ownerId == null) {
              status = 'negative';
              exitCode = 1;
            }
          } else {
            final id = invocation.operands.single;
            final node = plan.node(id);
            if (node == null) {
              status = 'error';
              exitCode = 2;
              diagnostics.add(
                _diagnostic(
                  'UNKNOWN_NODE_ID',
                  'error',
                  'Unknown node ID: $id.',
                ),
              );
            } else {
              payload = {'mode': 'id', 'node': node};
            }
          }
        }
      }
    } else {
      final InitResult result;
      try {
        result = await Bootstrap().initialize(
          root,
          options['--template']!,
          options.containsKey('--dry-run'),
        );
      } on FileSystemException catch (error) {
        return _failure(
          streams,
          command,
          'INIT_PREPARATION_FAILED',
          error.toString(),
          root: root,
        );
      } on UnsupportedError catch (error) {
        return _failure(
          streams,
          command,
          'INIT_UNAVAILABLE',
          error.toString(),
          root: root,
        );
      } on ArgumentError catch (error) {
        return _failure(
          streams,
          command,
          'INIT_UNAVAILABLE',
          error.toString(),
          root: root,
        );
      }
      status = {'planned', 'created'}.contains(result.outcome) ? 'ok' : 'error';
      exitCode = status == 'ok' ? 0 : 2;
      diagnostics = result.diagnostics
          .map(
            (d) => _diagnostic(
              d.code,
              'error',
              d.message,
              path: d.path,
              hints: [
                'Inspect the named paths and explicitly choose whether to keep, recover, or remove them before retrying.',
              ],
            ),
          )
          .toList();
      payload = {
        'template': result.template,
        'dry_run': result.dryRun,
        'outcome': result.outcome,
        'planned_paths': result.plannedPaths,
        'planned_files': result.plannedFiles
            .map((f) => {'path': f.path, 'content': f.content})
            .toList(),
        'created_paths': result.createdPaths,
        'residual_paths': result.residualPaths,
        'conflicting_paths': result.conflictingPaths,
      };
    }
    if (command == 'export' && exitCode == 0 && options['--out'] != null) {
      try {
        await _writeExport(
          root,
          options['--out']!,
          mermaid!,
          options.containsKey('--overwrite'),
        );
      } on FileSystemException catch (error) {
        status = 'error';
        exitCode = 2;
        diagnostics.add(
          _diagnostic(
            error is NativeIoException && error.category == IoCategory.exists
                ? 'EXPORT_TARGET_EXISTS'
                : 'EXPORT_WRITE_FAILED',
            'error',
            error.toString(),
            path: options['--out'],
          ),
        );
      } on UnsupportedError catch (error) {
        status = 'error';
        exitCode = 2;
        diagnostics.add(
          _diagnostic(
            'EXPORT_WRITE_FAILED',
            'error',
            error.toString(),
            path: options['--out'],
          ),
        );
      }
    }
    diagnostics.sort((a, b) {
      for (final key in [
        'path',
        'code',
        'rule_pointer',
        'project_id',
        'message',
      ]) {
        final av = a[key] as String?;
        final bv = b[key] as String?;
        final comparison = av == null
            ? (bv == null ? 0 : -1)
            : bv == null
            ? 1
            : comparePlanText(av, bv);
        if (comparison != 0) return comparison;
      }
      return 0;
    });
    if (command == 'export' && exitCode == 0 && options['--out'] == null) {
      streams.stdout.write(mermaid!);
    }
    if (command == 'export' && diagnostics.isEmpty) return exitCode;
    final output = command == 'export' ? streams.stderr : streams.stdout;
    output.writeln(
      jsonEncode({
        'command': command,
        'schema_version': 1,
        'tool_versions': {
          'archway': archwayVersion,
          'dart_adapter': null,
          'typescript_adapter': null,
          'dart_sdk': null,
          'node': null,
          'typescript': null,
          ...inspectionVersions,
        },
        'resolved_root': root,
        'policy_path': policyPath,
        'policy_hash': policyHash,
        'status': status,
        'exit_code': exitCode,
        'diagnostics': diagnostics,
        'payload': command == 'export'
            ? {'format': options['--format'], 'out': options['--out']}
            : payload,
      }),
    );
    return exitCode;
  }
}

Map<String, Object?> _diagnostic(
  String code,
  String severity,
  String message, {
  String? pointer,
  String? path,
  List<String> hints = const [],
}) => {
  'code': code,
  'severity': severity,
  'message': message,
  'rule_pointer': pointer,
  'source_range': null,
  'project_id': null,
  'path': path,
  'recovery_hints': hints,
};

int _usage(
  CliStreams streams,
  String? command,
  String message, {
  Map<String, Object?>? exportPayload,
}) => _failure(
  streams,
  command,
  'USAGE_ERROR',
  message,
  usage: true,
  exportPayload: exportPayload,
);

int _failure(
  CliStreams streams,
  String? command,
  String code,
  String message, {
  bool usage = false,
  Map<String, Object?>? exportPayload,
  String? root,
}) {
  final exit = usage ? 64 : 2;
  final output = command == 'export' ? streams.stderr : streams.stdout;
  output.writeln(
    jsonEncode({
      'command': command,
      'schema_version': 1,
      'tool_versions': {
        'archway': archwayVersion,
        'dart_adapter': null,
        'typescript_adapter': null,
        'dart_sdk': null,
        'node': null,
        'typescript': null,
      },
      'resolved_root': root,
      'policy_path': null,
      'policy_hash': null,
      'status': usage ? 'usage_error' : 'error',
      'exit_code': exit,
      'diagnostics': [_diagnostic(code, 'error', message)],
      'payload': command == 'export'
          ? exportPayload ?? {'format': null, 'out': null}
          : null,
    }),
  );
  return exit;
}

class _Invocation {
  String? command;
  final options = <String, String>{};
  final operands = <String>[];
  static const commands = {
    'init',
    'validate',
    'owner',
    'node',
    'allows',
    'check',
    'export',
  };
  Map<String, Object?> get exportPayload {
    String? out;
    try {
      if (options['--out'] != null) {
        out = normalizeRepositoryPath(options['--out']!, file: true);
      }
    } on FormatException {
      // Invalid or unavailable parsing is explicitly null in diagnostics.
    }
    return {
      'format': options['--format'] == 'mermaid' ? 'mermaid' : null,
      'out': out,
    };
  }

  // Recover command identity even when an earlier global option is invalid.
  String? _recognizeCommand(List<String> args) {
    var ended = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!ended && arg == '--') {
        ended = true;
        continue;
      }
      if (!ended && arg.startsWith('-')) {
        if ({
              '--root',
              '--policy',
              '--template',
              '--path',
              '--limit',
              '--offset',
              '--format',
              '--out',
            }.contains(arg) &&
            i + 1 < args.length &&
            !args[i + 1].startsWith('--'))
          i++;
        continue;
      }
      return commands.contains(arg) ? arg : null;
    }
    return null;
  }

  void parse(List<String> args) {
    command = _recognizeCommand(args);
    var commandSeen = false;
    var ended = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!ended && arg == '--') {
        ended = true;
        continue;
      }
      if (!ended && arg.startsWith('-')) {
        final equals = arg.indexOf('=');
        final flag = equals < 0 ? arg : arg.substring(0, equals);
        if (!{
          '--root',
          '--policy',
          '--template',
          '--dry-run',
          '--path',
          '--paths',
          '--limit',
          '--offset',
          '--format',
          '--out',
          '--overwrite',
        }.contains(flag)) {
          throw FormatException('Unsupported option: $flag.');
        }
        if (!commandSeen && flag != '--root') {
          throw const FormatException('Only --root may precede the command.');
        }
        if (options.containsKey(flag))
          throw FormatException('Repeated option: $flag.');
        if (flag == '--paths' && operands.isNotEmpty) {
          throw const FormatException(
            '--paths requires two following operands.',
          );
        }
        if (flag == '--dry-run' || flag == '--paths' || flag == '--overwrite') {
          if (equals >= 0) throw FormatException('$flag takes no value.');
          options[flag] = '';
        } else {
          if (equals >= 0) {
            options[flag] = arg.substring(equals + 1);
          } else {
            if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
              throw FormatException('Missing value for $flag.');
            }
            options[flag] = args[++i];
          }
          if (options[flag]!.isEmpty)
            throw FormatException('Empty value for $flag.');
        }
      } else if (!commandSeen) {
        if (!commands.contains(arg))
          throw FormatException('Unknown command: $arg.');
        command = arg;
        commandSeen = true;
      } else {
        operands.add(arg);
      }
    }
    if (command == null) throw const FormatException('A command is required.');
    if (!{
      'init',
      'validate',
      'owner',
      'node',
      'allows',
      'check',
      'export',
    }.contains(command)) {
      throw FormatException(
        '$command is not implemented in this development build.',
      );
    }
    if (operands.length !=
        (command == 'allows'
            ? 2
            : command == 'owner' ||
                  (command == 'node' &&
                      !options.containsKey('--path') &&
                      operands.isNotEmpty)
            ? 1
            : 0)) {
      throw const FormatException('Wrong number of operands.');
    }
    if (command == 'owner') operands[0] = normalizeRepositoryPath(operands[0]);
    if (command == 'allows' && options.containsKey('--paths')) {
      for (var i = 0; i < operands.length; i++)
        operands[i] = normalizeRepositoryPath(operands[i], file: true);
    }
    if (options.containsKey('--path'))
      options['--path'] = normalizeRepositoryPath(options['--path']!);
    final allowed = command == 'init'
        ? {'--root', '--template', '--dry-run'}
        : {
            '--root',
            '--policy',
            if (command == 'node') ...{'--path', '--limit', '--offset'},
            if (command == 'allows') '--paths',
            if (command == 'export') ...{'--format', '--out', '--overwrite'},
          };
    if (options.keys.any((flag) => !allowed.contains(flag))) {
      throw FormatException('An option is incompatible with $command.');
    }
    if (options.containsKey('--overwrite') && !options.containsKey('--out')) {
      throw const FormatException('--overwrite requires --out.');
    }
    if (options.containsKey('--out')) {
      options['--out'] = normalizeRepositoryPath(options['--out']!, file: true);
    }
    if (command == 'export' && options['--format'] != 'mermaid') {
      throw const FormatException('export requires --format mermaid.');
    }
    if (command == 'node') {
      for (final flag in ['--limit', '--offset']) {
        final raw = options[flag];
        if (raw == null) continue;
        final number = int.tryParse(raw);
        if (operands.isNotEmpty ||
            options.containsKey('--path') ||
            !RegExp(r'^[0-9]+$').hasMatch(raw) ||
            number == null ||
            number < (flag == '--limit' ? 1 : 0)) {
          throw const FormatException(
            'Pagination requires nonnegative catalogue integers and a positive limit.',
          );
        }
      }
    }
    final root = options['--root'];
    if (root != null && RegExp(r'[\x00-\x1f\x7f]').hasMatch(root)) {
      throw const FormatException('--root contains control characters.');
    }
    final policy = options['--policy'];
    if (policy != null) {
      final portable = unicode.nfc(policy.replaceAll('\\', '/'));
      final normalized = path.posix.normalize(portable);
      if (RegExp(r'[\x00-\x1f\x7f:*?"<>|\[\]{}]').hasMatch(portable) ||
          portable
              .split('/')
              .any(
                (segment) =>
                    (!{'.', '..'}.contains(segment) &&
                        (segment.endsWith('.') || segment.endsWith(' '))) ||
                    RegExp(
                      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                      caseSensitive: false,
                    ).hasMatch(segment),
              ) ||
          portable.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(portable) ||
          portable.endsWith('/') ||
          {'.', '..'}.contains(portable.split('/').last) ||
          normalized == '..' ||
          normalized.startsWith('../') ||
          normalized == '.') {
        throw const FormatException(
          '--policy must be a portable root-relative file path.',
        );
      }
      options['--policy'] = normalized;
    }
    if (command == 'init' &&
        !{'dart', 'typescript', 'mixed'}.contains(options['--template'])) {
      throw const FormatException(
        'init requires --template dart|typescript|mixed.',
      );
    }
  }
}

String _help(String? command) => switch (command) {
  'init' => 'archway [--root ROOT] init --template dart|typescript|mixed [--dry-run]\nCreates architecture.yaml and ARCHITECTURE.md without overwrite.',
  'validate' => 'archway [--root ROOT] validate [--policy PATH]\nValidates the declared flat policy without compiler runtimes.',
  'owner' => 'archway [--root ROOT] owner [--policy PATH] PATH\nReturns lexical ownership for an existing or future path.',
  'node' => 'archway [--root ROOT] node [--policy PATH] [--limit N] [--offset N]\narchway [--root ROOT] node [--policy PATH] ID\narchway [--root ROOT] node [--policy PATH] --path PATH\nReturns the complete sorted catalogue or full direct module context. Only explicit pagination omits entries.',
  'check' => 'archway [--root ROOT] check [--policy PATH]\nChecks the independently enumerated source corpus against declared boundaries.',
  'allows' => 'archway [--root ROOT] allows [--policy PATH] FROM_ID TO_ID\narchway [--root ROOT] allows [--policy PATH] --paths FROM TO\nQueries direct module permission or exact-file public access without resolving or inspecting files.',
  'export' => 'archway [--root ROOT] export [--policy PATH] --format mermaid [--out PATH [--overwrite]]\nExports the complete declared graph. Mermaid goes to stdout or the file; JSON diagnostics go to stderr.',
  null => 'archway [--root ROOT] COMMAND [OPTIONS]\nImplemented: init, validate, owner, node, allows, check, export.\nUse COMMAND --help or --version. Operational results are JSON, except Mermaid export with separate JSON diagnostics.',
  _ =>
    'archway $command\nThis v1 command is not implemented in this development build.',
};

String _mermaid(Plan plan, String hash) {
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
