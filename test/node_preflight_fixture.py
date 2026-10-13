"""Compiled native preflight faults; real Node still handles compiler requests."""
import json
from pathlib import Path
import subprocess
import tempfile
from process_fixture_support import dart_executable, dart_string


def compile_node_fixture(sdk, destination, node):
    destination = Path(destination)
    config = destination.with_name('preflight.json')
    source = f'''import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {{
  final config = jsonDecode(File({dart_string(config)}).readAsStringSync());
  if (args.length == 1 && args.first == '--version') {{
    if (config['marker'] != null) {{
      File(config['marker']).writeAsStringSync('queried');
    }}
    stdout.write(config['version']);
    stderr.add(List<int>.filled(config['stderr_bytes'], 120));
    await stdout.flush();
    await stderr.flush();
    if (config['delay_ms'] > 0) {{
      await Future<void>.delayed(Duration(milliseconds: config['delay_ms']));
    }}
    exitCode = config['exit_code'];
  }} else {{
    final child = await Process.start({dart_string(node)}, args);
    await Future.wait([
      stdin.pipe(child.stdin),
      child.stdout.pipe(stdout),
      child.stderr.pipe(stderr),
    ]);
    exitCode = await child.exitCode;
  }}
}}
'''
    with tempfile.TemporaryDirectory(prefix='archway-node-fixture-') as temp:
        program = Path(temp) / 'fixture.dart'
        program.write_text(source, encoding='utf-8')
        subprocess.run([str(dart_executable(sdk)), '--suppress-analytics', 'compile',
                        'exe', str(program), '-o', str(destination)],
                       check=True, capture_output=True, timeout=90)

    def configure(*, version='v24.21.0\n', stderr_bytes=0, delay_ms=0,
                  exit_code=0, marker=None):
        config.write_text(json.dumps(dict(version=version, stderr_bytes=stderr_bytes,
                          delay_ms=delay_ms, exit_code=exit_code, marker=marker)), encoding='utf-8')
    return configure
