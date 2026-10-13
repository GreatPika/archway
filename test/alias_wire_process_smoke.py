"""Protocol-v2 alias evidence at the real CLI seam, using captured helper facts."""
import base64
import copy
import json
import os
from pathlib import Path
from installation_staging import stage_installation
import subprocess
import sys
import tempfile
from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable, node = [Path(value).resolve() for value in sys.argv[1:3]]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
count = 0
with tempfile.TemporaryDirectory(prefix='archway-alias-wire-') as temporary:
    base = Path(temporary).resolve()
    install = base / 'installation'
    install.mkdir()
    binary = stage_installation(executable, install)
    root = base / 'project'
    (root / 'src/app').mkdir(parents=True)
    (root / 'src/core').mkdir()
    (root / 'src/app/main.ts').write_text("import '../core/private';")
    (root / 'src/core/private.ts').write_text('export {};')
    (root / 'actual.json').write_text('{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}')
    (root / 'first.json').symlink_to('actual.json')
    (root / 'second.json').symlink_to('actual.json')
    (root / 'config.alias.json').symlink_to('first.json')
    (root / 'tsconfig.json').write_text('{"extends":"./config.alias.json","include":["src/**/*.ts"]}')
    policy = '''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
'''
    (root / 'architecture.yaml').write_text(policy)
    def invoke(expected):
        global count
        result = subprocess.run([str(binary), '--root', str(root), 'check'], cwd=base,
            env={**os.environ, 'PATH':str(node.parent)}, capture_output=True, timeout=15)
        assert result.returncode == expected, (result.stdout, result.stderr)
        assert result.stderr == b'' and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout)
        schema.validate(value)
        count += 1
        return value['payload']
    assert invoke(1)['analysis_complete']
    helper = install / 'assets/typescript/helper.cjs'
    request = {'protocol_version':2, 'request_id':'check:web', 'project_id':'web',
        'root_uri':root.as_uri(), 'config_path':'tsconfig.json', 'expected_files':['src/app/main.ts','src/core/private.ts']}
    baseline = json.loads(subprocess.run([str(node), str(helper)], input=json.dumps(request).encode(),
        capture_output=True, check=True).stdout)
    alias_index = next(i for i, value in enumerate(baseline['inputs']) if value['observed_uri'] == (root / 'config.alias.json').as_uri())
    assert len(baseline['inputs'][alias_index]['symlink_hops']) == 2
    def canned(value, extra=''):
        encoded = base64.b64encode(json.dumps(value).encode()).decode()
        helper.write_text("let s='';process.stdin.on('data',b=>s+=b);process.stdin.on('end',()=>{const request=JSON.parse(s);const value=JSON.parse(Buffer.from('" + encoded + "','base64'));" + extra + ";process.stdout.write(JSON.stringify(value));});")
    def malformed(edit):
        value = copy.deepcopy(baseline)
        edit(value)
        canned(value)
        result = invoke(2)
        assert result['facts']['edges'] == []
        assert any(d['code'] == 'TYPESCRIPT_HELPER_FAILED' for d in result['tool_errors'])
    malformed(lambda v: v.update(protocol_version=1))
    malformed(lambda v: v['inputs'][alias_index].pop('symlink_hops'))
    for hop in [
        {'observed_uri':'file:///', 'target':'first.json'},
        {'observed_uri':(root / 'config.alias.json').as_uri(), 'target':''},
        {'observed_uri':(root / 'config.alias.json').as_uri(), 'target':'bad\0name'},
        {'observed_uri':(root / 'config.alias.json').as_uri(), 'target':'bad\ud800'},
        {'observed_uri':(root / 'config.alias.json').as_uri(), 'target':'first.json', 'extra':True},
    ]:
        malformed(lambda v, hop=hop: v['inputs'][alias_index].update(symlink_hops=[hop]))
    malformed(lambda v: v['inputs'][alias_index].update(symlink_hops=v['inputs'][alias_index]['symlink_hops'] * 21))

    # A single witness list can itself contain inconsistent observations of one
    # repeated completed hop. It is a conflict, not a malformed envelope.
    value = copy.deepcopy(baseline)
    alias_uri = (root / 'config.alias.json').as_uri()
    conflicting = value['inputs'][alias_index]
    value['inputs'] = [entry for entry in value['inputs'] if entry is conflicting or
        not any(hop['observed_uri'] == alias_uri for hop in entry['symlink_hops'])]
    conflicting['symlink_hops'].append({'observed_uri':alias_uri, 'target':'second.json'})
    canned(value)
    result = invoke(2)
    assert result['facts']['edges'] == []
    assert not result['tool_errors']
    assert any(d['code'] == 'INPUT_CHANGED' for d in result['unknowns'])

    # Structurally valid freshness disagreement must not become an envelope error.
    for transform in [lambda hops: [], lambda hops: list(reversed(hops))]:
        value = copy.deepcopy(baseline)
        for entry in value['inputs']:
            entry['symlink_hops'] = transform(entry['symlink_hops'])
        canned(value)
        result = invoke(2)
        assert any(d['code'] == 'INPUT_CHANGED' for d in result['unknowns'])
        assert result['facts']['edges'] and result['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
        assert not result['tool_errors']

    # Same physical link, different raw-target baselines invalidates BOTH suppliers.
    (root / 'architecture.yaml').write_text(policy.replace(
        'projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]',
        'projects: [{id: a, adapter: typescript, tsconfig: tsconfig.json}, {id: b, adapter: typescript, tsconfig: tsconfig.json}]'))
    canned(baseline, "value.request_id=request.request_id;value.project_id=request.project_id;"
        "if(request.project_id==='b'){for(const entry of value.inputs){for(const hop of entry.symlink_hops){"
        "if(hop.observed_uri.endsWith('/config.alias.json'))hop.target='second.json';}}}")
    result = invoke(2)
    assert result['facts']['edges'] == []
    assert not result['tool_errors']
    assert all(not f['discovery_complete'] and f['unresolved_project_ids'] == ['a','b'] for f in result['coverage']['files'])
    assert all(p['status'] == 'partial' for p in result['coverage']['projects'])
    assert any(d['code'] == 'INPUT_CHANGED' for d in result['unknowns'])
print(f'{count} bounded alias-wire process checks passed')
