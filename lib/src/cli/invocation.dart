import 'package:path/path.dart' as path;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../plan/repository_path.dart';

class Invocation {
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
    if (command == 'init') {
      options.putIfAbsent('--template', () => 'dart');
      if (options['--template'] != 'dart') {
        throw const FormatException('init supports only --template dart.');
      }
    }
  }
}

String invocationHelp(String? command) => switch (command) {
  'init' => 'archway [--root ROOT] init [--template dart] [--dry-run]\nCreates architecture.yaml and ARCHITECTURE.md without overwrite.',
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
