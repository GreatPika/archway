// Developer-only npm-shim command encoder. Production archway.cjs never uses a shell.
// Argument escaping adapted from @npmcli/promise-spawn 9.0.1 (npm 11.19.0).
// Copyright (c) npm, Inc. (ISC)
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
// THE SOFTWARE IS PROVIDED "AS IS" AND THE NPM DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE NPM BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
// OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.
import 'package:path/path.dart' as p;

import '../../test/support/windows_command.dart';
import '../../test/support/windows_process.dart';

final _meta = RegExp(r'[ !%^&()<>|"]');
String _escape(String value) =>
    value.replaceAllMapped(_meta, (match) => '^${match[0]}');

String _argument(String value) {
  if (value.isEmpty) return '""';
  final quoted = RegExp('[ \\t\\v"]').hasMatch(value)
      ? windowsCommandLine([value])
      : value;
  // npm's generated .cmd forwards %*, introducing a second cmd parse.
  return _escape(_escape(quoted));
}

WindowsRawCommandLine windowsNpmShimCommand(
  List<String> arguments, {
  required String cmdExecutable,
  required String nodeExecutable,
  required String shimSource,
  required Map<String, String> environment,
}) {
  if (arguments.isEmpty ||
      !p.windows.isAbsolute(arguments.first) ||
      !arguments.first.toLowerCase().endsWith('.cmd') ||
      !p.windows.isAbsolute(cmdExecutable) ||
      p.windows.basename(cmdExecutable).toLowerCase() != 'cmd.exe' ||
      !p.windows.isAbsolute(nodeExecutable) ||
      [
        cmdExecutable,
        nodeExecutable,
        ...arguments,
      ].any((value) => value.contains(RegExp('[\\x00\\r\\n]')))) {
    throw ArgumentError(
      'Expected absolute npm shim/runtime paths and single-line arguments',
    );
  }
  final encoded = arguments.skip(1).map(_argument).join(' ');
  final script =
      '${_escape(arguments.first)}${encoded.isEmpty ? '' : ' $encoded'}';
  final raw = '"$cmdExecutable" /d /s /v:off /e:on /c "$script"';
  // Fail closed unless the known npm shim expansions can also fit cmd's limit.
  final values = {
    for (final entry in environment.entries)
      entry.key.toUpperCase(): entry.value,
  };
  final pathExt = values['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD';
  if (!RegExp(r'^[.;A-Za-z0-9]*$').hasMatch(pathExt) ||
      values['COMSPEC'] != cmdExecutable ||
      !shimSource.contains('%*')) {
    throw ArgumentError(
      'Unbounded npm shim environment or forwarding template',
    );
  }
  final directory = '${p.windows.dirname(arguments.first)}\\';
  final longestNode = nodeExecutable.length > '${directory}node.exe'.length
      ? nodeExecutable
      : '${directory}node.exe';
  // Match only the original template. Substituted paths/arguments are literal
  // values and must never be rescanned as another environment expansion.
  final replacements = {
    '%~dp0': directory,
    '%dp0%': directory,
    '%_prog%': longestNode,
    '%COMSPEC%': cmdExecutable,
    '%PATHEXT:;.JS;=;%': pathExt.replaceAll(';.JS;', ';'),
    '%*': encoded,
  };
  final expanded = shimSource.replaceAllMapped(
    RegExp(replacements.keys.map(RegExp.escape).join('|') + '|%'),
    (match) {
      final replacement = replacements[match[0]];
      if (replacement == null)
        throw ArgumentError('Unknown npm shim expansion');
      return replacement;
    },
  );
  if (raw.length > 8191 ||
      expanded.split(RegExp(r'\r?\n')).any((line) => line.length > 8191)) {
    throw ArgumentError('npm shim command exceeds the Windows cmd limit');
  }
  return WindowsRawCommandLine(
    applicationName: cmdExecutable,
    commandLine: raw,
    logicalArguments: arguments,
  );
}
