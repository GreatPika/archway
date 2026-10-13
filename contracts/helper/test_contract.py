import copy,json,pathlib
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError
from validate_contract import validate,D,REQUEST,RESPONSE
r=json.loads((D/'fixtures/valid-request.json').read_text()); s=json.loads((D/'fixtures/valid-response.json').read_text())
cases=[]
def case(name,edit,valid=False):
    a,b=copy.deepcopy(r),copy.deepcopy(s); edit(a,b); cases.append((name,a,b,valid))
case('complete',lambda a,b:None,True)
def failed(a,b):
    b['status']='failed';b['tool_errors']=[{'code':'HELPER_ANALYSIS_FAILED','message':'Failure after verified source extraction','path':None,'source_range':None}];b['files'][0]['coverage']='partial'
case('failed-with-verified-facts',failed,True)
def unresolved(a,b):
    b['status']='incomplete';b['facts'][0]['resolution']={'kind':'unresolved'};b['unknowns']=[{'code':'UNRESOLVED_IMPORT','message':'No target','path':'src/main.ts','source_range':b['facts'][0]['source_range']}]
case('unresolved-incomplete',unresolved,True)
case('wrong-version',lambda a,b:b.update(protocol_version=1))
case('wrong-project',lambda a,b:b.update(project_id='other'))
case('wrong-request',lambda a,b:b.update(request_id='other'))
case('extra-policy-result',lambda a,b:b.update(allowed=True))
case('missing-file',lambda a,b:b.update(files=[]))
case('duplicate-file',lambda a,b:b['files'].append(copy.deepcopy(b['files'][0])))
case('dangling-evidence',lambda a,b:b['facts'][0]['input_ids'].append('missing'))
def reversed_span(a,b):
    b['facts'][0]['source_range']['start'].update(column=2)
    b['facts'][0]['source_range']['end'].update(column=1)
case('reversed-span',reversed_span)
case('zero-based-span',lambda a,b:b['facts'][0]['source_range']['start'].update(line=0))
case('parent-source-path',lambda a,b:b['facts'][0].update(source='../outside.ts'))
case('unresolved-complete',lambda a,b:b['facts'][0].update(resolution={'kind':'unresolved'}))
case('partial-complete',lambda a,b:b['files'][0].update(coverage='partial'))
case('wrong-source-identity',lambda a,b:b['inputs'][0].update(observed_uri='file:///repo/other.ts'))
case('duplicate-input',lambda a,b:b['inputs'].append(copy.deepcopy(b['inputs'][0])))
case('failed-without-error',lambda a,b:b.update(status='failed'))
case('missing-config-input',lambda a,b:b['inputs'].pop())
case('fact-from-failed-file',lambda a,b:(failed(a,b),b['files'][0].update(coverage='failed')))
def nonmember(a,b):
    b['files'][0].update(membership='nonmember',coverage='not_applicable',input_id=None);b['facts']=[]
case('nonmember-complete-project',nonmember,True)
def unknown(a,b):
    failed(a,b);b['files'][0].update(membership='unknown',coverage='failed',input_id=None);b['facts']=[]
case('unknown-membership-failed',unknown,True)
def outside(a,b):
    b['facts'][0]['resolution'].update(path=None,canonical_file_uri='file:///outside/dep.ts');b['inputs'][1].update(observed_uri='file:///outside/dep.ts',canonical_uri='file:///outside/dep.ts')
case('outside-local-target',outside,True)
case('target-without-evidence',lambda a,b:b['facts'][0]['resolution'].update(canonical_file_uri='file:///other.ts'))
case('unknown-membership-complete',lambda a,b:b['files'][0].update(membership='unknown'))
case('drive-source-path',lambda a,b:a.update(expected_files=['C:/file.ts']))
case('trailing-slash-path',lambda a,b:a.update(config_path='config/'))
case('uri-remote-authority',lambda a,b:a.update(root_uri='file://remote/repo'))
case('target-path-uri-mismatch',lambda a,b:b['facts'][0]['resolution'].update(path='src/other.ts'))
case('observed-identity-conflict',lambda a,b:b['inputs'].append({**b['inputs'][0],'id':'ix','sha256':'d'*64}))
case('source-canonical-outside-root',lambda a,b:b['inputs'][0].update(canonical_uri='file:///outside/main.ts'))
case('inside-target-null-path',lambda a,b:b['facts'][0]['resolution'].update(path=None))
def zero_diagnostic(a,b):
    unresolved(a,b);b['unknowns'][0]['source_range']=copy.deepcopy(b['unknowns'][0]['source_range']);b['unknowns'][0]['source_range']['end']=copy.deepcopy(b['unknowns'][0]['source_range']['start'])
case('zero-width-diagnostic',zero_diagnostic,True)
case('zero-width-edge',lambda a,b:b['facts'][0]['source_range'].update(end=copy.deepcopy(b['facts'][0]['source_range']['start'])))
def filesystem_root(a,b):
    a['root_uri']='file:///'
    for i in b['inputs']:
        i['observed_uri']=i['observed_uri'].replace('file:///repo/','file:///');i['canonical_uri']=i['canonical_uri'].replace('file:///repo/','file:///')
    b['facts'][0]['resolution']['canonical_file_uri']='file:///src/dep.ts'
    b['inputs'].append({'id':'inventory-root','kind':'directory','observed_uri':'file:///','canonical_uri':'file:///','sha256':'e'*64,'symlink_hops':[]})
case('filesystem-root-and-inventory',filesystem_root,True)
case('empty-file-uri',lambda a,b:b['inputs'][0].update(observed_uri='file:///'))
passed=0
for name,a,b,valid in cases:
    if name in ('reversed-span', 'zero-width-edge'):
        span = b['facts'][0]['source_range']
        start = (span['start']['line'], span['start']['column'])
        end = (span['end']['line'], span['end']['column'])
        assert end < start if name == 'reversed-span' else end == start, name
    try:validate(a,b);actual=True
    except Exception:actual=False
    assert actual==valid,name
    passed+=1
try:validate(r,s,exit_code=1);raise AssertionError('nonzero exit accepted')
except ValueError:passed+=1
print(f'PASS {passed} cases; Draft 2020-12 schemas checked; no runtime/compiler compatibility implied')
from validate_contract import decode_envelope,validate_transport
transport_cases=[('at-caps',(8*1048576,64*1048576,256*1024,120,0,True),True),('request-over',(8*1048576+1,1,0,1,0,True),False),('stdout-over',(1,64*1048576+1,0,1,0,True),False),('stderr-over',(1,1,256*1024+1,1,0,True),False),('timeout',(1,1,0,120.001,0,True),False),('exit',(1,1,0,1,1,True),False),('no-eof',(1,1,0,1,0,False),False)]
for name,args,valid in transport_cases:
    try:validate_transport(*args);actual=True
    except ValueError:actual=False
    assert actual==valid,name
framing_cases=[('valid',b' {} \n',True),('duplicate',b'{"a":1,"a":2}',False),('partial',b'{"a":',False),('two-values',b'{} {}',False),('invalid-utf8',b'{"a":"\xff"}',False),('bom',b'\xef\xbb\xbf{}',False),('nan',b'{"a":NaN}',False)]
for name,raw,valid in framing_cases:
    try:decode_envelope(raw);actual=True
    except (ValueError,UnicodeError):actual=False
    assert actual==valid,name
print(f'PASS {len(transport_cases)+len(framing_cases)} additional framing/transport cases (modeled boundaries, no OS process launched)')


def test_empty_authoritative_corpus():
    # protocol.md: one request per declared project, containing the full corpus.
    # json/decision.md: coverage includes declared projects with zero files.
    request = copy.deepcopy(r)
    request['expected_files'] = []
    response = copy.deepcopy(s)
    response['files'] = []
    response['facts'] = []
    response['inputs'] = [copy.deepcopy(s['inputs'][-1])]  # Config evidence.
    assert validate(request, response)

    rejected = [
        ('missing corpus', lambda a, b: a.pop('expected_files')),
        ('null corpus', lambda a, b: a.update(expected_files=None)),
        ('nonarray corpus', lambda a, b: a.update(expected_files='')),
        ('nonstring file', lambda a, b: a.update(expected_files=[None])),
        ('malformed file', lambda a, b: a.update(expected_files=['../a.ts'])),
        ('duplicate file', lambda a, b: a.update(expected_files=['a.ts', 'a.ts'])),
        ('wrong request', lambda a, b: b.update(request_id='other')),
        ('wrong project', lambda a, b: b.update(project_id='other')),
        ('unexpected coverage', lambda a, b: b.update(files=copy.deepcopy(s['files']))),
        ('unexpected fact', lambda a, b: b.update(facts=copy.deepcopy(s['facts']))),
        ('missing config evidence', lambda a, b: b.update(inputs=[])),
    ]
    for name, edit in rejected:
        a, b = copy.deepcopy(request), copy.deepcopy(response)
        edit(a, b)
        try:
            validate(a, b)
        except (ValueError, ValidationError):
            continue
        raise AssertionError('Empty corpus accepted ' + name)


test_empty_authoritative_corpus()
print('PASS empty authoritative corpus and 11 invalid-envelope regressions')


def test_protocol_v2_inputs():
    base = copy.deepcopy(s)
    base['inputs'].extend([
        {'id': 'directory', 'kind': 'directory', 'observed_uri': 'file:///repo/src',
         'canonical_uri': 'file:///repo/src', 'sha256': 'e' * 64, 'symlink_hops': []},
        {'id': 'missing', 'kind': 'absent', 'observed_uri': 'file:///repo/missing',
         'canonical_uri': None, 'symlink_hops': []},
    ])
    hop = {'observed_uri': 'file:///repo/link', 'target': './src'}
    def hops(response, value):
        response['inputs'][1]['observed_uri'] = 'file:///repo/link/dep.ts'
        response['facts'][0]['resolution']['via_path'] = 'file:///repo/link/dep.ts'
        response['inputs'][1]['symlink_hops'] = value
    cases = [('empty-hops-all-input-kinds', lambda a, b: None, True)]
    def case(name, edit, valid=False):
        cases.append((name, edit, valid))
    case('v1-rejected', lambda a, b: (a.update(protocol_version=1), b.update(protocol_version=1)))
    for index in (0, 3, 4):
        case(f'missing-hops-kind-{index}', lambda a, b, i=index: b['inputs'][i].pop('symlink_hops'))
    case('nonarray-hops', lambda a, b: hops(b, None))
    case('nonobject-hop', lambda a, b: hops(b, ['link']))
    for field in ('observed_uri', 'target'):
        case('missing-' + field, lambda a, b, f=field: hops(b, [{k: v for k, v in hop.items() if k != f}]))
    case('extra-hop-key', lambda a, b: hops(b, [{**hop, 'hash': 'a' * 64}]))
    for target in ('', '\x00', '\ud800', '\udfff', None, 1):
        case('invalid-target-' + repr(target), lambda a, b, t=target: hops(b, [{**hop, 'target': t}]))
    for uri in ('file:///', 'file:///C:/', 'file:///repo/link/', 'file://remote/link',
                'file:///repo/link?q', 'file:///repo/link#f', 'file:///repo/./link',
                'file:///repo/%FF', 'file:///repo/%6cink', 'file:///repo/link\n', 'relative/link'):
        case('invalid-uri-' + uri, lambda a, b, u=uri: hops(b, [{**hop, 'observed_uri': u}]))
    # Raw targets are not repository paths and must not be normalized.
    for target in ('/', '../src/./dep', '/outside/root', 'e\u0301', '\ufffd', '\U0001f680'):
        case('raw-target-' + repr(target), lambda a, b, t=target: hops(b, [{**hop, 'target': t}]), True)
    case('absent-with-ancestor-hop', lambda a, b: b['inputs'][4].update(
        observed_uri='file:///repo/link/missing', symlink_hops=[hop]), True)
    case('directory-link-to-root', lambda a, b: b['inputs'][3].update(
        observed_uri='file:///repo/link', canonical_uri='file:///',
        symlink_hops=[{**hop, 'target': '/'}]), True)
    case('completed-hop-repeated', lambda a, b: hops(b, [hop, hop]), True)
    case('forty-hops', lambda a, b: hops(b, [hop] * 40), True)
    case('forty-one-hops', lambda a, b: hops(b, [hop] * 41))
    def distinct_routes(a, b):
        hops(b, [hop])
        b['inputs'].append({**copy.deepcopy(b['inputs'][1]), 'id': 'alias2',
                           'observed_uri': 'file:///repo/other/dep.ts',
                           'symlink_hops': [{'observed_uri': 'file:///repo/other', 'target': './src'}]})
    case('distinct-stable-routes-share-content', distinct_routes, True)
    def conflicting_hop(a, b):
        distinct_routes(a, b)
        b['inputs'][-1]['symlink_hops'] = [{**hop, 'target': './changed-route'}]
    # Even helper status complete does not make a freshness conflict malformed.
    # Parent aggregation must invalidate affected evidence and mark incomplete.
    case('shared-link-conflict-needs-aggregation', conflicting_hop, True)
    def freshness_change(a, b):
        hops(b, [hop])
        b['status'] = 'incomplete'
        b['tool_errors'] = [{'code': 'INPUT_CHANGED', 'message': 'Route changed',
                            'path': None, 'source_range': None}]
    case('valid-baseline-with-freshness-change', freshness_change, True)
    for name, edit, expected in cases:
        request, response = copy.deepcopy(r), copy.deepcopy(base)
        edit(request, response)
        try:
            validate(request, response)
            actual = True
        except (ValueError, ValidationError, UnicodeError):
            actual = False
        assert actual == expected, name
    print(f'PASS {len(cases)} protocol v2 structural cases; no filesystem retrace or aggregation executed')


test_protocol_v2_inputs()
