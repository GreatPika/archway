"""Executable decision model only. Does not simulate or certify Dart/TS SDK semantics."""
import json
from pathlib import Path

def assign(file):
    if not file['supported_source']: return 'unsupported'
    if not file['discovery_complete']: return 'failed'
    candidates={(x['project_id'],x['context_id']) for x in file['candidates']}
    return 'missing' if not candidates else 'assigned' if len(candidates)==1 else 'ambiguous'

fixtures=json.loads(Path(__file__).with_name('fixtures.json').read_text())
assert len(fixtures)==26
for fixture in fixtures:
    actual=assign(fixture)
    assert actual==fixture['expected_assignment'],(fixture['id'],actual)
    # Candidate ordering, duplicate observations, and YAML order must not change result.
    assert assign({**fixture,'candidates':list(reversed(fixture['candidates']))})==actual
    assert assign({**fixture,'candidates':fixture['candidates']*2})==actual
    if actual=='assigned':
        assert len({(x['project_id'],x['context_id']) for x in fixture['candidates']})==1
# Every observed input, including unsupported/missing/failed, remains represented.
coverage=[{'path':f['path'],'fixture':f['id'],'assignment':assign(f)} for f in fixtures]
assert len(coverage)==len(fixtures)
assert {x['fixture'] for x in coverage}=={f['id'] for f in fixtures}
print(f'PASS: {len(fixtures)} decision fixtures, ordering/duplicate invariance, corpus conservation.')
print('NOT RUN: real Dart analyzer, TS Compiler API, reference redirects, OS/archive acceptance.')
import hashlib
context=json.loads(Path(__file__).with_name('context-id-fixture.json').read_text())
encoded=json.dumps(context['descriptor'],sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
assert encoded.decode()==context['canonical_descriptor_utf8']
assert hashlib.sha256(encoded).hexdigest()==context['descriptor_sha256']
assert context['context_id']=='dart:'+context['project_id']+':'+context['descriptor_sha256']
assert set(context['descriptor'])=={'root','included_paths','excluded_paths','package_config_path','options_paths','sdk_version'}
for field in ['included_paths','excluded_paths','options_paths']:
    assert context['descriptor'][field]==sorted(set(context['descriptor'][field]))
print('PASS: Dart context descriptor canonical encoding and SHA-256 fixture.')
