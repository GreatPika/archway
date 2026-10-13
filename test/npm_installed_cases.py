"""CLI seam checks against an actually installed private Linux npm package."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from jsonschema import Draft202012Validator


def exercise(launcher, root, cwd, node, wrong_node, environment, repository):
    package = launcher.resolve().parent.parent
    public = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
    count = 0
    def run(args, expected=0, path=None):
        nonlocal count
        result = subprocess.run([str(node), str(launcher), '--root', str(root), *args],
                                cwd=cwd, env={**environment, 'PATH': path or str(node.parent)},
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == expected, (args, result.stdout, result.stderr)
        count += 1
        return result
    def report(args, expected=0, path=None):
        result = run(args, expected, path)
        assert result.stderr == '', result.stderr
        value = json.loads(result.stdout)
        public.validate(value)
        assert value['exit_code'] == expected
        return value
    report(['init', '--template', 'mixed'], path='/missing-runtime')
    for args in [['validate'], ['node'], ['export', '--format', 'mermaid'],
                 ['unknown; $(touch should-not-exist)'], ['--help']]:
        direct = subprocess.run([str(package / 'bin/linux-x64/archway'), '--root', str(root), *args],
                                cwd=cwd, env=environment, capture_output=True, text=True)
        wrapped = run(args, direct.returncode)
        assert (wrapped.stdout, wrapped.stderr) == (direct.stdout, direct.stderr), args
    assert not (cwd / 'should-not-exist').exists()
    run(['export', '--format', 'mermaid', '--out', 'diagram café.mmd'], path='/missing-runtime')
    assert (root / 'diagram café.mmd').read_text().endswith('flowchart LR\n')
    (root / 'src').mkdir(exist_ok=True)
    (root / 'src/main.ts').write_text('export const value = 1;\n')
    (root / 'tsconfig.json').write_text('{"include":["src/**/*.ts"]}')
    policy = '''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
'''
    (root / 'architecture.yaml').write_text(policy)
    marker = root / 'project-decoy-executed'
    for relative in ['assets/typescript/helper.cjs', 'node_modules/typescript/lib/typescript.js']:
        decoy = root / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) + ", 'executed');throw Error('decoy');")
    value = report(['check'])
    assert value['payload']['analysis_complete'] and value['tool_versions']['typescript'] == '5.9.3'
    assert not marker.exists()
    for path in ['/missing-runtime', str(wrong_node.parent)]:
        assert report(['check'], 2, path)['payload']['tool_errors'][0]['code'] == 'NODE_UNAVAILABLE'
    # Node can launch the wrapper even when no verified analysis Node is on PATH.
    report(['validate'], path='/missing-runtime')
    assets = package / 'assets/typescript'
    for relative in ['helper.cjs', 'vendor/typescript/lib/typescript.js']:
        asset = assets / relative
        saved = asset.rename(asset.with_suffix(asset.suffix + '.saved'))
        assert report(['check'], 2)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
        asset.symlink_to(saved)
        assert report(['check'], 2)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
        asset.unlink()
        saved.rename(asset)
    helper = assets / 'helper.cjs'
    original = helper.read_bytes()
    helper.write_text('this is not JavaScript!')
    assert report(['check'], 2)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_HELPER_FAILED'
    helper.write_bytes(original)
    bridge = package / 'native/linux-x64/libarchway_io.so'
    saved = bridge.rename(bridge.with_suffix('.saved'))
    report(['validate'])
    run(['export', '--format', 'mermaid', '--out', 'missing-bridge.mmd'], 2)
    assert not (root / 'missing-bridge.mmd').exists()
    saved.rename(bridge)
    if package.is_relative_to(root):
        selected = (assets / 'helper.cjs').relative_to(root).as_posix()
        expanded = policy.replace('scope: [src/]', 'scope: [src/, ' + json.dumps(selected) + ']')
        (root / 'architecture.yaml').write_text(expanded)
        assert any(f['path'] == selected for f in report(['check'], 2)['payload']['coverage']['files'])
        (root / 'architecture.yaml').write_text(expanded.replace('exclude: []', 'exclude: [' + json.dumps(selected) + ']'))
        assert not any(f['path'] == selected for f in report(['check'])['payload']['coverage']['files'])
        (root / 'architecture.yaml').write_text(policy)
    # Compare actual native termination with the wrapped route on this OS.
    ready = cwd / 'helper-ready'
    termination_results = {}
    for termination in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        observed = []
        for command in [[str(package / 'bin/linux-x64/archway')], [str(node), str(launcher)]]:
            helper.write_text("require('node:fs').writeFileSync(" + json.dumps(str(ready)) +
                              ", JSON.stringify([process.pid, process.ppid]));setTimeout(()=>process.exit(0),10000);")
            process = subprocess.Popen([*command, '--root', str(root), 'check'],
                                       cwd=cwd, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 8
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert ready.exists(), 'Real core did not reach helper before signal test'
                helper_pid, core_pid = json.loads(ready.read_text())
                process.send_signal(termination)
                stdout, stderr = process.communicate(timeout=3)
                observed.append((process.returncode, stdout, stderr))
                try:
                    os.kill(core_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError('Core survived forwarded signal')
                count += 1
            finally:
                # Own isolated process group only: also clean a core left by failed forwarding.
                # This fixture cleanup is not a product process-tree termination guarantee.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if ready.exists():
                    ready.unlink()
                process.wait(timeout=3)
                helper.write_bytes(original)
        assert observed[0] == observed[1], (termination, observed)
        termination_results[termination.name] = observed[0][0]
    for name in ['architecture.yaml', 'ARCHITECTURE_AGENT.md', 'diagram café.mmd']:
        (root / name).unlink()
    return {'cases': count, 'termination': termination_results}
