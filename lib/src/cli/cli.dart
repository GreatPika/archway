import 'dart:io';

import 'package:path/path.dart' as path;

import '../bootstrap/bootstrap.dart';
import '../plan/policy_definition.dart';
import '../plan/policy_loader.dart';
import '../inspection/inspection.dart';
import '../native/native_io.dart';
import '../native/physical_paths.dart';
import 'cli_output.dart';
import 'export_file.dart';
import 'invocation.dart';
import 'mermaid.dart';

export 'cli_output.dart' show CliStreams, archwayVersion;

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
            Invocation.commands.contains(args.first) &&
            args.last == '--help')) {
      final command = args.length == 2 ? args.first : null;
      streams.stdout.writeln(invocationHelp(command));
      return 0;
    }
    final invocation = Invocation();
    try {
      invocation.parse(args);
    } on FormatException catch (error) {
      return cliUsage(
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
        return cliUsage(
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
        return cliUsage(
          streams,
          command,
          '--root must select an existing directory.',
          exportPayload: invocation.exportPayload,
        );
      }
      return cliFailure(
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
      final loaded = await loadPlan(RepositorySelection(root, policyPath));
      policyHash = loaded.policyHash;
      status = loaded.status;
      exitCode = status == 'ok' ? 0 : 2;
      diagnostics = loaded.diagnostics
          .map(
            (d) => cliDiagnostic(
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
          mermaid = formatMermaid(plan, policyHash!);
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
              cliDiagnostic(
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
                cliDiagnostic(
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
        return cliFailure(
          streams,
          command,
          'INIT_PREPARATION_FAILED',
          error.toString(),
          root: root,
        );
      } on UnsupportedError catch (error) {
        return cliFailure(
          streams,
          command,
          'INIT_UNAVAILABLE',
          error.toString(),
          root: root,
        );
      } on ArgumentError catch (error) {
        return cliFailure(
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
            (d) => cliDiagnostic(
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
        await writeExport(
          root,
          options['--out']!,
          mermaid!,
          options.containsKey('--overwrite'),
        );
      } on FileSystemException catch (error) {
        status = 'error';
        exitCode = 2;
        diagnostics.add(
          cliDiagnostic(
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
          cliDiagnostic(
            'EXPORT_WRITE_FAILED',
            'error',
            error.toString(),
            path: options['--out'],
          ),
        );
      }
    }
    return writeCliResult(
      streams: streams,
      command: command,
      root: root,
      policyPath: policyPath,
      policyHash: policyHash,
      status: status,
      exitCode: exitCode,
      diagnostics: diagnostics,
      inspectionVersions: inspectionVersions,
      payload: payload,
      mermaid: mermaid,
      exportToStdout: options['--out'] == null,
      exportPayload: {'format': options['--format'], 'out': options['--out']},
    );
  }
}
