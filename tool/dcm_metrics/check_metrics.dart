import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.contains('--help')) {
      stdout.writeln(
        'dart run tool/dcm_metrics/check_metrics.dart '
        '[--root=PATH] [--dcm=EXECUTABLE_OR_DART_SCRIPT] '
        '[--timeout-seconds=120]',
      );
      return;
    }
    final options = _options(arguments);
    final root = Directory(options['root'] ?? Directory.current.path)
        .resolveSymbolicLinksSync();
    final files = await _dartFiles(root);
    if (files.isEmpty) throw StateError('No Dart files found in repository.');
    final report = Directory.systemTemp.createTempSync('archway-dcm-metrics-');
    stdout.writeln('Report: ${report.path}');
    final run = _MetricsRun(
      root: root,
      report: report,
      executable: options['dcm'] ?? 'dcm',
      timeout: Duration(
        seconds: int.parse(options['timeout-seconds'] ?? '120'),
      ),
    );
    await run.scan('.', files);
    exitCode = run.finish(files);
  } on Object catch (error) {
    stderr.writeln('Metrics check incomplete: $error');
    exitCode = 2;
  }
}

Map<String, String> _options(List<String> arguments) {
  final options = <String, String>{};
  for (final argument in arguments) {
    final parts = argument.split('=');
    final name = parts.first.replaceFirst('--', '');
    if (!argument.startsWith('--') ||
        parts.length < 2 ||
        !const ['root', 'dcm', 'timeout-seconds'].contains(name)) {
      throw ArgumentError('Unknown option: $argument');
    }
    options[name] = parts.skip(1).join('=');
  }
  final seconds = int.tryParse(options['timeout-seconds'] ?? '120');
  if (seconds == null || seconds <= 0) {
    throw ArgumentError('timeout-seconds must be positive.');
  }
  return options;
}

Future<List<String>> _dartFiles(String root) async {
  final top = await Process.run('git', [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: root);
  if (top.exitCode != 0 ||
      Directory((top.stdout as String).trim()).resolveSymbolicLinksSync() !=
          root) {
    throw ArgumentError('--root must be a Git repository root.');
  }
  final result = await Process.run('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
    '--',
    '*.dart',
  ], workingDirectory: root);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  return (result.stdout as String)
      .split('\x00')
      .where((path) {
        return path.isNotEmpty && File('$root/$path').existsSync();
      })
      .toSet()
      .toList()
    ..sort();
}

final class _MetricsRun {
  _MetricsRun({
    required this.root,
    required this.report,
    required this.executable,
    required this.timeout,
  });

  final String root;
  final Directory report;
  final String executable;
  final Duration timeout;
  final _entries = <Map<String, Object>>[];

  Future<void> scan(String scope, List<String> files) async {
    final id = _entries.length + 1;
    final entry = <String, Object>{'scope': scope, 'log': '$id.log'};
    _entries.add(entry);
    final result = await _execute(scope);
    File('${report.path}/$id.log').writeAsStringSync(result.text);
    final status = _classify(result);
    entry['status'] = status;
    entry['exitCode'] = result.code;
    if (status == 'limit' && files.any((file) => file != scope)) {
      entry['status'] = 'split';
      stdout.writeln('SPLIT $scope');
      for (final child in _children(scope, files).entries) {
        await scan(child.key, child.value);
      }
      return;
    }
    entry['files'] = files;
    entry['violations'] = _violations(result.text);
    stdout.writeln('${status.toUpperCase()} $scope');
  }

  Future<({int code, String text})> _execute(String scope) async {
    final args = [
      'calculate-metrics',
      scope,
      '--concise',
      '--fatal-level=high',
      '--no-analytics',
    ];
    final isDart = executable.endsWith('.dart');
    try {
      final process = await Process.start(
        isDart ? Platform.resolvedExecutable : executable,
        [if (isDart) executable, ...args],
        workingDirectory: root,
      );
      final captured = await _capture(process, timeout);
      final text = captured.text
          .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')
          .replaceAll('\r', '\n');
      return (code: captured.code, text: text);
    } on ProcessException catch (error) {
      return (code: -1, text: '$error');
    }
  }

  int finish(List<String> files) {
    final leaves = _entries
        .where((entry) => entry['status'] != 'split')
        .toList();
    final complete = leaves.every(
      (entry) => entry['status'] == 'clean' || entry['status'] == 'violations',
    );
    final violations =
        leaves
            .expand((entry) => entry['violations']! as List<String>)
            .toSet()
            .toList()
          ..sort();
    final code = !complete ? 2 : (violations.isEmpty ? 0 : 1);
    final status = !complete
        ? 'incomplete'
        : (code == 0 ? 'clean' : 'violations');
    final summary = <String, Object>{
      'status': status,
      'complete': complete,
      'root': root,
      'inventory': files,
      'parts': _entries,
      'checkedParts': leaves.length,
      'violations': violations,
    };
    _writeSummary(report, summary);
    return code;
  }
}

Future<({int code, String text})> _capture(
  Process process,
  Duration timeout,
) async {
  final output = StringBuffer();
  final errors = StringBuffer();
  final out = process.stdout.transform(utf8.decoder).listen(output.write);
  final err = process.stderr.transform(utf8.decoder).listen(errors.write);
  try {
    // Bound exit and pipe drainage together: CLI wrappers may leave inherited
    // pipes open in child processes even after the wrapper itself has exited.
    final results = await Future.wait<int>([
      process.exitCode,
      out.asFuture<void>().then((_) => 0),
      err.asFuture<void>().then((_) => 0),
    ]).timeout(timeout);
    return (code: results.first, text: '$output\n$errors');
  } on Object catch (error) {
    process.kill(ProcessSignal.sigkill);
    return (code: -1, text: '$error\n$output\n$errors');
  } finally {
    await out.cancel();
    await err.cancel();
  }
}

void _writeSummary(Directory report, Map<String, Object> summary) {
  File('${report.path}/summary.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(summary)}\n',
  );
  final violations = summary['violations']! as List<String>;
  for (final violation in violations) {
    stdout.writeln(violation);
  }
  stdout.writeln(
    'Metrics ${summary['status']}: '
    '${summary['checkedParts']} parts, ${violations.length} violations.',
  );
}

Map<String, List<String>> _children(String scope, List<String> files) {
  final groups = <String, List<String>>{};
  final prefix = scope == '.' ? '' : '$scope/';
  for (final file in files) {
    final child = '$prefix${file.replaceFirst(prefix, '').split('/').first}';
    groups.putIfAbsent(child, () => []).add(file);
  }
  return groups;
}

List<String> _violations(String text) => text
    .split('\n')
    .where((line) => RegExp(r'^• .+:\d+:\d+ ').hasMatch(line))
    .toList();

// Keep exit-code and output checks together to classify each DCM result atomically.
// ignore: cyclomatic-complexity
String _classify(({int code, String text}) result) {
  if (result.code == 1 &&
      RegExp(r'Unable to show[^\n]*exceed your plan limit')
          .hasMatch(result.text)) {
    return 'limit';
  }
  if (result.text.contains('Config errors:')) return 'error';
  if (result.text.contains('All analyzed contexts were skipped'))
    return 'error';
  if ((result.code == 0 || result.code == 2) &&
      result.text.contains('Scanned files:') &&
      _violations(result.text).isNotEmpty) {
    return 'violations';
  }
  if (result.code == 0 && result.text.contains('no metric violations found')) {
    return 'clean';
  }
  return 'error';
}
