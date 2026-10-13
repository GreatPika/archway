"""Real native PATH/preflight/installed-compiler checks, through CLI transport.

Arguments: AOT executable, pinned Node, real wrong-version Node, pinned Dart SDK.
Trusted fixture runtimes exercise raw preflight boundaries; they are never placed
inside or loaded from the inspected project. This is not target certification.
"""
import json
import os
from pathlib import Path
import shutil
from installation_staging import stage_installation
from process_fixture_support import compile_runtime_tripwire
from node_preflight_fixture import compile_node_fixture
import subprocess
import sys
import tempfile
import time

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable, node, wrong_node, sdk = [Path(p).resolve() for p in sys.argv[1:5]]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
count = 0
with tempfile.TemporaryDirectory(prefix='archway-preflight-') as temp:
    base = Path(temp).resolve()
    install = base / 'installation'
    install.mkdir()
    archway = stage_installation(executable, install)
    root = base / 'project'
    (root / 'lib/app').mkdir(parents=True)
    (root / 'lib/core').mkdir()
    (root / '.dart_tool').mkdir()
    (root / 'lib/app/main.dart').write_text("import '../core/private.dart';\n")
    (root / 'lib/core/private.dart').write_text('class Value {}\n')
    (root / 'tsconfig.json').write_text('{"files":[]}')
    (root / 'pubspec.yaml').write_text('name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
    (root / '.dart_tool/package_config.json').write_text(json.dumps({'configVersion': 2,
        'packages': [{'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'}]}))
    (root / 'architecture.yaml').write_text('''version: 1
projects:
  - {id: dart, adapter: dart, package_roots: [./]}
  - {id: web, adapter: typescript, tsconfig: tsconfig.json}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''')
    command = [str(archway), '--root', str(root), 'check']
    def invoke(path, code='NODE_UNAVAILABLE', env=None):
        global count
        process = subprocess.run(command, cwd=base, env={**os.environ,
            'PATH': path + os.pathsep + str(sdk / 'bin'), **(env or {})},
            capture_output=True, timeout=15)
        assert process.returncode == 2 and process.stderr == b'', (process.stdout, process.stderr)
        assert process.stdout.endswith(b'\n') and process.stdout.count(b'\n') == 1
        value = json.loads(process.stdout)
        schema.validate(value)
        assert value['exit_code'] == 2
        assert code in [e['code'] for e in value['payload']['tool_errors']], value['payload']['tool_errors']
        # A TypeScript failure cannot erase reliable Dart facts or violations.
        assert value['tool_versions']['dart_sdk'] == '3.13.3'
        assert value['payload']['facts']['edges'][0]['project_id'] == 'dart'
        assert value['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
        count += 1
        return value

    assert subprocess.check_output([str(wrong_node), '--version']).strip() != b'v24.21.0'
    value = invoke(str(wrong_node.parent))
    assert value['tool_versions']['node'] is None
    assert '24.21.0 required' in value['payload']['tool_errors'][0]['message']
    invoke('/nonexistent/runtime')

    marker = base / 'project-code-executed'
    runtime_name = 'node.exe' if os.name == 'nt' else 'node'
    malicious = root / runtime_name
    compile_runtime_tripwire(sdk, malicious, marker)
    for path in [str(root), str(root / 'nested/..'), '.', '', os.pathsep + str(root), str(root / '../project')]:
        invoke(path)
        assert not marker.exists(), 'Repository runtime or relative PATH was executed'
    alias = base / 'alias-runtime'
    alias.mkdir()
    (alias / runtime_name).symlink_to(malicious)
    invoke(str(alias))
    assert not marker.exists()
    # An entry resolving to the invocation cwd must also be ignored.
    shutil.copy2(malicious, base / runtime_name)
    invoke(str(base))
    assert not marker.exists()

    runtime = base / 'trusted runtime'
    runtime.mkdir()
    binary = runtime / runtime_name
    preflight = compile_node_fixture(sdk, binary, node)
    preflight(marker=str(marker), version='')
    for args in [['--help'], ['--version'], ['--root', str(root), 'validate']]:
        result = subprocess.run([str(archway), *args], cwd=base,
            env={**os.environ, 'PATH': str(runtime)}, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stderr == b'', (result.stdout, result.stderr)
        assert not marker.exists(), 'Non-check command queried a runtime'
        if args[-1] == 'validate':
            schema.validate(json.loads(result.stdout))
        count += 1

    # Exactly 64 KiB combined output succeeds preflight (the real compiler then
    # reports its empty-files configuration error); +1 fails in the adapter.
    for extra in [0, 1]:
        preflight(stderr_bytes=65536 - len(b'v24.21.0\n') + extra)
        value = invoke(str(runtime), 'TYPESCRIPT_CONFIG_ERROR' if extra == 0 else 'NODE_UNAVAILABLE')
        assert value['tool_versions']['node'] == ('24.21.0' if extra == 0 else None)
        if extra:
            assert 'limit exceeded' in value['payload']['tool_errors'][0]['message']
    preflight(version="", delay_ms=60000)
    started = time.monotonic()
    value = invoke(str(runtime))
    assert 4.9 <= time.monotonic() - started < 9
    assert 'deadline exceeded' in value['payload']['tool_errors'][0]['message']
    preflight(exit_code=9)
    assert 'code 9' in invoke(str(runtime))['payload']['tool_errors'][0]['message']

    loader = root / 'loader.cjs'
    loader.write_text('require("node:fs").writeFileSync(' + json.dumps(str(marker)) + ',"executed");')
    value = invoke(str(node.parent), 'TYPESCRIPT_CONFIG_ERROR', {
        'NODE_OPTIONS': '--require=' + str(loader), 'NODE_PATH': str(root),
        'LD_LIBRARY_PATH': str(root), 'DYLD_LIBRARY_PATH': str(root)})
    assert value['tool_versions']['node'] == '24.21.0'
    assert not marker.exists()

    # Project source, scripts, compiler plugins and preload tripwires are data.
    # Syscall tracing is a separate release gate: this host denies ptrace.
    source = root / 'lib/main.ts'
    source.write_text('require("node:fs").writeFileSync(' + json.dumps(str(marker)) + ',"executed");')
    (root / 'package.json').write_text(json.dumps({'scripts': {
        'preinstall': str(node) + ' ' + str(loader),
        'build': str(node) + ' ' + str(loader)}}))
    (root / 'plugin.cjs').write_bytes(loader.read_bytes())
    (root / 'tsconfig.json').write_text(json.dumps({'files': ['lib/main.ts'],
        'compilerOptions': {'plugins': [{'name': './plugin.cjs'}]}}))
    traced = subprocess.run(command, cwd=base, env={**os.environ,
        'PATH': str(node.parent) + os.pathsep + str(sdk / 'bin'),
        'NODE_OPTIONS': '--require=' + str(loader)}, capture_output=True, timeout=15)
    assert traced.returncode == 2 and traced.stderr == b'', (traced.stdout, traced.stderr)
    schema.validate(json.loads(traced.stdout))
    assert not marker.exists(), 'Project code was executed'
    count += 1
    source.unlink()
    (root / 'tsconfig.json').write_text('{"files":[]}')

    compiler = install / 'assets/typescript/vendor/typescript/lib/typescript.js'
    original = compiler.read_bytes()
    compiler.write_text('module.exports = {version:"0.0.0"};')
    value = invoke(str(node.parent), 'TYPESCRIPT_VERSION_MISMATCH')
    assert value['tool_versions']['typescript'] is None
    compiler.write_text('throw new Error("cannot load installed compiler");')
    value = invoke(str(node.parent), 'TYPESCRIPT_LOAD_FAILED')
    assert value['tool_versions']['typescript'] is None
    compiler.write_bytes(original)
    (install / 'assets/typescript/framing.cjs').unlink()
    invoke(str(node.parent), 'TYPESCRIPT_ASSETS_UNAVAILABLE')

print(f'{count} real preflight/retention/schema checks passed.')
