"""Real native helper lifecycle and byte-budget acceptance through CLI.run.

Arguments: AOT executable, pinned Node binary. Assets are copied into a trusted
fixture installation; never install or execute anything from a project.
"""
import json
import base64
import os
from pathlib import Path
from installation_staging import stage_installation
from process_lifecycle_support import start_interruptible, interrupt, is_alive, terminate_pid
import subprocess
import sys
import tempfile
import time

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable, node = [Path(p).resolve() for p in sys.argv[1:3]]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
count = 0

with tempfile.TemporaryDirectory(prefix='archway-runtime-') as temp:
    base = Path(temp).resolve()
    install = base / 'installation café'
    install.mkdir()
    binary = stage_installation(executable, install)
    helper = install / 'assets/typescript/helper.cjs'
    root = base / 'project'
    root.mkdir()
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: []
exclude: []
nodes: []
''')
    (root / 'tsconfig.json').write_text('{"files":[]}')
    environment = {**os.environ, 'PATH': str(node.parent)}
    command = [str(binary), '--root', str(root), 'check']

    def validate(result, expected):
        global count
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'', result.stderr
        assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout)
        schema.validate(value)
        assert value['exit_code'] == expected
        count += 1
        return value

    def invoke(expected, timeout=15, env=None):
        return validate(subprocess.run(command, cwd=base, env=env or environment,
            capture_output=True, timeout=timeout), expected)

    protocol = json.loads((repository / 'contracts/helper/request.schema.json').read_text())['properties']['protocol_version']['const']
    request = {'protocol_version': protocol, 'request_id': 'check:web',
        'project_id': 'web', 'root_uri': root.as_uri(),
        'config_path': 'tsconfig.json', 'expected_files': []}
    captured = subprocess.run([str(node), str(helper)], input=json.dumps(request).encode(),
        capture_output=True, check=True, env={k: v for k, v in environment.items()
            if not k.upper().startswith(('NODE_', 'LD_', 'DYLD_'))}).stdout
    envelope = json.loads(captured)
    # This trusted fixture supplies a structurally complete zero-source response
    # so exact byte limits discriminate accepted evidence from transport failure.
    envelope.update(status='complete', unknowns=[], tool_errors=[])
    raw = json.dumps(envelope, separators=(',', ':')).encode()
    payload_js = "Buffer.from('" + base64.b64encode(raw).decode() + "','base64')"
    def canned(before='', after=''):
        helper.write_text("process.stdin.resume();process.stdin.on('end',()=>{" +
            before + "process.stdout.write(" + payload_js + ");" + after + "});")

    canned()
    assert invoke(0)['payload']['analysis_complete']
    # A complete frame is not usable until zero exit AND both stream EOFs.
    canned(after="process.stdout.end();process.stderr.end();setTimeout(()=>process.exit(9),250);")
    value = invoke(2)
    assert 'code 9' in value['payload']['tool_errors'][0]['message']
    # Parent exit arrives before a descendant closes the inherited output pipe.
    for suffix, expected in [(' ', 0), ('x', 2)]:
        child_pid_file = base / ('late-output-' + str(expected) + '.pid')
        child_done = base / ('late-output-' + str(expected) + '.done')
        child = ("setTimeout(()=>process.stdout.write(" + json.dumps(suffix) +
            ",error=>{if(error)throw error;require('node:fs').writeFileSync(" + json.dumps(str(child_done)) +
            "," + json.dumps(suffix) + ");}),250)")
        # libuv's Windows job kills non-detached descendants on parent exit;
        # unref alone does not let this deliberate late writer survive.
        canned(after="const child=require('node:child_process').spawn(process.execPath,['-e'," + json.dumps(child) +
            "],{detached:process.platform==='win32',stdio:['ignore',1,2]});" +
            "require('node:fs').writeFileSync(" + json.dumps(str(child_pid_file)) +
            ",String(child.pid));child.unref();process.exit(0);")
        try:
            value = invoke(expected)
            assert child_done.read_text() == suffix, 'Late writer did not complete'
            assert value['payload']['analysis_complete'] == (expected == 0)
        finally:
            if child_pid_file.exists():
                terminate_pid(int(child_pid_file.read_text()))
    # Raw bytes at the response cap are accepted, first byte over invalidates all.
    for extra in [0, 1]:
        canned(before="process.stdout.write(Buffer.alloc(" + str(64 * 1024 * 1024 - len(raw) + extra) + ",32));")
        value = invoke(0 if extra == 0 else 2, timeout=30)
        assert value['payload']['analysis_complete'] == (extra == 0)
        if extra:
            assert 'stdout limit' in value['payload']['tool_errors'][0]['message']
    for extra in [0, 1]:
        canned(before="process.stderr.write(Buffer.alloc(" + str(256 * 1024 + extra) + ",120));")
        value = invoke(0 if extra == 0 else 2)
        assert value['payload']['analysis_complete'] == (extra == 0)
        if extra:
            assert 'stderr limit' in value['payload']['tool_errors'][0]['message']

    # SIGINT must yield an incomplete report after killing/reaping the helper.
    pid_file = base / 'helper.pid'
    helper.write_text("require('node:fs').writeFileSync(" + json.dumps(str(pid_file)) +
        ",String(process.pid));process.stdin.resume();setInterval(()=>{},1000);")
    process = start_interruptible(command, cwd=base, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        started = time.monotonic()
        while not pid_file.exists() and time.monotonic() - started < 5:
            time.sleep(.02)
        assert pid_file.exists(), 'Helper did not start'
        child_pid = int(pid_file.read_text())
        interrupt(process)
        out, err = process.communicate(timeout=5)
        value = validate(subprocess.CompletedProcess(command, process.returncode, out, err), 2)
        assert any('cancelled' in e['message'].lower() for e in value['payload']['tool_errors'])
        assert value['payload']['facts']['edges'] == []
        assert not is_alive(child_pid), 'Cancelled helper is still alive'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if pid_file.exists():
            terminate_pid(int(pid_file.read_text()))

    # Exercise the actual 120-second production budget, with no clock override.
    pid_file.unlink()
    helper.write_text("require('node:fs').writeFileSync(" + json.dumps(str(pid_file)) +
        ",String(process.pid));process.stdin.resume();process.stdout.write(" + payload_js +
        ");setInterval(()=>{},1000);")
    started = time.monotonic()
    value = invoke(2, timeout=130)
    elapsed = time.monotonic() - started
    assert 119 <= elapsed < 126, elapsed
    assert 'deadline exceeded' in value['payload']['tool_errors'][0]['message']
    assert not value['payload']['analysis_complete']
    assert not is_alive(int(pid_file.read_text())), 'Timed-out helper is still alive'

print(f'{count} real runtime lifecycle/schema checks passed.')
