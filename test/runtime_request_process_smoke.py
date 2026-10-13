"""Real exact 8 MiB request / first byte over checks through CLI.run on native hosts.

The corpus is real files sharing a long portable prefix. No production deadline
or request encoder override is used. Args: AOT executable, pinned Node binary,
optional coverage-failure JSON artifact path.
"""
import json
import os
from pathlib import Path
from installation_staging import stage_installation
from long_path_fixture import fixture_path, remove_fixture_tree
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable, node = [Path(p).resolve() for p in sys.argv[1:3]]
failure_report = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else None
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
protocol = json.loads((repository / 'contracts/helper/request.schema.json').read_text())['properties']['protocol_version']['const']
compact = lambda value: json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()
with tempfile.TemporaryDirectory(prefix='archway-request-') as temp:
    base = Path(temp).resolve()
    install = base / 'installation'
    install.mkdir()
    binary = stage_installation(executable, install)
    root = base / 'project'
    root.mkdir()
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: all, responsibility: All, owns: [src/], allows: [], public: []}]
''')
    (root / 'tsconfig.json').write_text('{}')
    request = {'protocol_version': protocol, 'request_id': 'check:web',
        'project_id': 'web', 'root_uri': root.as_uri(),
        'config_path': 'tsconfig.json', 'expected_files': []}
    # Use more files rather than exceed macOS's full-path limit with deep names.
    prefix = 'src/' + '/'.join('a' * 190 for _ in range(3))
    first = prefix + '/file-00000.ts'
    # Each nonempty array element costs its string bytes + quotes + comma;
    # subtract the nonexistent final comma once.
    available = 8 * 1024 * 1024 - len(compact(request)) + 1
    n = available // (len(first) + 3)
    rest = available - n * (len(first) + 3)
    if rest < 12:
        n -= 1
        rest += len(first) + 3
    paths = [prefix + f'/file-{i:05}.ts' for i in range(n)]
    target_length = rest - 3
    tail = 'src/'
    while target_length - len(tail) > 203:
        tail += 'z' * 190 + '/'
    tail += 'z' * (target_length - len(tail) - 3) + '.ts'
    paths.append(tail)
    request['expected_files'] = sorted(paths)
    assert len(compact(request)) == 8 * 1024 * 1024
    # Extended Win32 syntax is fixture-only; the CLI still receives the ordinary
    # root and must enumerate the genuine long native corpus itself.
    try:
        for path in paths:
            file = fixture_path(root / path)
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('export {};\n')
        marker = base / 'request-size'
        helper = install / 'assets/typescript/helper.cjs'
        helper.write_text("const chunks=[];process.stdin.on('data',b=>chunks.push(b));process.stdin.on('end',()=>{" +
            "const raw=Buffer.concat(chunks),r=JSON.parse(raw);require('node:fs').writeFileSync(" +
            json.dumps(str(marker)) + ",String(raw.length));process.stdout.write(JSON.stringify({" +
            "protocol_version:r.protocol_version,request_id:r.request_id,project_id:r.project_id,status:'failed'," +
            "files:r.expected_files.map(path=>({path,membership:'unknown',coverage:'failed',input_id:null}))," +
            "facts:[],inputs:[],unknowns:[],tool_errors:[{code:'REQUEST_ACCEPTED',message:'Accepted exact request',path:null,source_range:null}]}));});")
        command = [str(binary), '--root', str(root), 'check']
        def invoke(code):
            result = subprocess.run(command, cwd=base, env={**os.environ, 'PATH': str(node.parent)},
                capture_output=True, timeout=90)
            assert result.returncode == 2 and result.stderr == b'', (result.returncode, result.stderr)
            assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
            value = json.loads(result.stdout)
            schema.validate(value)
            assert value['exit_code'] == 2 and not value['payload']['analysis_complete']
            if len(value['payload']['coverage']['files']) != len(paths):
                try:
                    if failure_report is not None:
                        failure_report.write_bytes(result.stdout)
                    actual = {entry['path'] for entry in value['payload']['coverage']['files']}
                    expected_paths = set(paths)
                    print(json.dumps({
                        'request_coverage_mismatch': {
                            'expected_count': len(paths),
                            'actual_count': len(value['payload']['coverage']['files']),
                            'missing_sample': sorted(expected_paths - actual)[:3],
                            'unexpected_sample': sorted(actual - expected_paths)[:3],
                            'observed': value['payload']['observed'],
                            'unknowns': value['payload']['unknowns'][:8],
                            'tool_errors': value['payload']['tool_errors'][:8],
                            'helper_request_bytes': marker.read_text() if marker.exists() else None,
                            'full_report': str(failure_report) if failure_report is not None else None,
                        },
                    }), file=sys.stderr)
                except Exception as error:
                    print(json.dumps({'request_coverage_diagnostic_error': str(error)}), file=sys.stderr)
            assert len(value['payload']['coverage']['files']) == len(paths)
            assert value['payload']['facts']['edges'] == []
            assert code in [e['code'] for e in value['payload']['tool_errors']]
            return value
        invoke('REQUEST_ACCEPTED')
        assert marker.read_text() == str(8 * 1024 * 1024)
        marker.unlink()
        changed = tail[:-3] + 'z.ts'
        fixture_path(root / tail).rename(fixture_path(root / changed))
        paths[-1] = changed
        request['expected_files'] = sorted(paths)
        assert len(compact(request)) == 8 * 1024 * 1024 + 1
        result = invoke('TYPESCRIPT_HELPER_FAILED')
        assert 'request exceeds 8 MiB' in result['payload']['tool_errors'][0]['message']
        assert not marker.exists(), 'Oversize request launched a helper'
    finally:
        remove_fixture_tree(root / 'src')

print('2 real request byte-boundary/schema checks passed.')
