"""Linux entrypoint exit regression with a real pending native child handle.

Arguments: pinned Dart binary, pinned Node binary. The generated driver imports
our real entrypoint; it adds no production flag or alternate CLI implementation.
The outer harness is a child subreaper and kills/reaps every fixture child.
"""
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
dart, node = [Path(p).resolve() for p in sys.argv[1:3]]
if not sys.platform.startswith('linux'):
    raise RuntimeError('This bounded child-subreaper fixture requires Linux.')
if ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    raise RuntimeError('Host refused fixture child reaping.')
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
with tempfile.TemporaryDirectory(prefix='entrypoint-', dir=repository / 'build') as temp:
    base = Path(temp)
    root = base / 'project'
    root.mkdir()
    (root / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    pid_file = base / 'child.pid'
    driver = base / 'driver.dart'
    driver.write_text("import 'dart:io';\nimport '" + (repository / 'bin/archway.dart').as_uri() + "' as command;\n" +
        "Future<void> main() async {\n" +
        "final child = await Process.start(" + json.dumps(str(node)) + ", ['-e','setTimeout(()=>{},20000)']);\n" +
        "await child.stdin.close(); await child.stdout.listen((_) {}).cancel(); await child.stderr.listen((_) {}).cancel();\n" +
        "await File(" + json.dumps(str(pid_file)) + ").writeAsString('${child.pid}');\n" +
        "await command.main(['--root'," + json.dumps(str(root)) + ",'validate']);\n}\n")
    process = subprocess.Popen([str(dart), '--suppress-analytics', 'run', str(driver)],
        cwd=repository, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert select.select([process.stdout], [], [], 15)[0], 'No entrypoint report'
        line = process.stdout.readline()
        value = json.loads(line)
        schema.validate(value)
        assert line.endswith(b'\n') and value['exit_code'] == 0
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            raise AssertionError('Entrypoint stayed alive after flushed report because a native child handle is pending')
        rest, error = process.communicate(timeout=1)
        assert process.returncode == 0 and rest == b'' and error == b'', (rest, error)
    finally:
        child_pid = int(pid_file.read_text()) if pid_file.exists() else None
        if child_pid is not None:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        if child_pid is not None:
            try:
                os.waitpid(child_pid, 0)
            except ChildProcessError:
                # A still-live driver may already have reaped its own child.
                pass

print('1 real entrypoint exit/schema check passed; fixture child killed and reaped.')
