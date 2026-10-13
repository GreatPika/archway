import json, pathlib, importlib.util, copy
from jsonschema import Draft202012Validator
B=pathlib.Path(__file__).resolve().parents[1]
def loadmod(n,p):
 s=importlib.util.spec_from_file_location(n,B/p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
j=loadmod('pub','json/verify_contract.py');h=loadmod('help','helper/validate_contract.py');l=loadmod('lex','compatibility/test_lexical_reference.py')
v=Draft202012Validator(json.loads((B/'json/public-result.schema.json').read_text()))
def fixture(n):return json.loads((B/'json/fixtures'/n).read_text())
def accepted(x):
 try:v.validate(x);j.invariants(x);return True
 except Exception:return False
results=[]
def case(name,x,expected=False):
 a=accepted(x);results.append({'case':name,'expected_accept':expected,'actual_accept':a,'pass':a==expected})
x=fixture('check-complete-fact.json');x['payload']['input_identity']['inputs']=[];case('complete-with-no-input-evidence',x)
x=fixture('check-complete-fact.json');x['payload']['facts']['edges'][0]['context_id']='typescript:other';case('fact-context-not-candidate',x)
x=fixture('check-complete-fact.json');x['payload']['facts']['edges'][0]['resolution']={'kind':'unresolved'};case('complete-with-unresolved-fact',x)
x=fixture('check-complete-fact.json');x['payload']['input_identity']['inputs'].append({'kind':'resolution','location':{'kind':'repository','path':'src/absent.ts'},'presence':'absent','hash':'sha256:'+'a'*64});case('absent-probe-with-present-hash',x)
x=fixture('check-complete-fact.json');x['payload']['coverage']['files'][0]['discovery_complete']=False;case('assigned-incomplete-discovery',x)
for outcome in ['planned','created','conflict','rolled_back','partial']:
 x=fixture('init-'+outcome+'.json');x['policy_path']='architecture.yaml';x['policy_hash']='sha256:'+'a'*64;case('init-'+outcome+'-with-policy-identity',x)
x=fixture('check-mixed-incomplete.json');x['status']='negative';x['exit_code']=1;case('incomplete-evidence-negative-status',x)
x=fixture('check-complete-fact.json');x['payload']['coverage']['files'][0]['path']='src/';case('coverage-directory-path',x)
r=json.loads((B/'helper/fixtures/valid-request.json').read_text());s=json.loads((B/'helper/fixtures/valid-response.json').read_text())
for name,mutate in [
 ('helper-target-path-uri-mismatch',lambda x:x['facts'][0]['resolution'].update(path='src/other.ts')),
 ('helper-observed-identity-conflict',lambda x:x['inputs'].append({**x['inputs'][0],'id':'ix','sha256':'d'*64})),
 ('helper-source-canonical-outside',lambda x:x['inputs'][0].update(canonical_uri='file:///outside/main.ts'))]:
 x=copy.deepcopy(s);mutate(x)
 try:h.validate(r,x);a=True
 except Exception:a=False
 results.append({'case':name,'expected_accept':False,'actual_accept':a,'pass':not a})
for p in ['src/[x].ts','src/{x}.ts']:
 try:l.normalize(p);a=True
 except ValueError:a=False
 results.append({'case':'lexical-reserved-'+p,'expected_accept':False,'actual_accept':a,'pass':not a})
for raw,want in [('.', './'),('a/..','./'),('src/A.ts','src/A.ts'),('src/a.ts','src/a.ts')]:
 a=l.normalize(raw);results.append({'case':'lexical-positive-'+raw,'pass':a==want,'actual':a})

# Extra cross-contract tests added by independent reviewer.
a=loadmod('assignment','assignment/verify.py')
assignment_cases=0
for supported in [False,True]:
 for discovered in [False,True]:
  for count in [0,1,2]:
   f={'supported_source':supported,'discovery_complete':discovered,'candidates':[{'project_id':str(i),'context_id':'typescript:'+str(i)} for i in range(count)]}
   want='unsupported' if not supported else 'failed' if not discovered else ['missing','assigned','ambiguous'][count]
   assert a.assign(f)==want
   assignment_cases+=1
rr=copy.deepcopy(r);ss=copy.deepcopy(s);rr['root_uri']='file:///'
for i in ss['inputs']:
 i['observed_uri']=i['observed_uri'].replace('file:///repo/','file:///')
 i['canonical_uri']=i['canonical_uri'].replace('file:///repo/','file:///')
ss['facts'][0]['resolution']['canonical_file_uri']='file:///src/dep.ts'
try:h.validate(rr,ss);ok=True
except Exception:ok=False
results.append({'case':'helper-filesystem-root-valid','expected_accept':True,'actual_accept':ok,'pass':ok})
x=fixture('check-complete-fact.json');x['payload']['input_identity']['inputs'][0]['hash']='sha256:'+'f'*64;case('policy-hash-disagrees-input-identity',x)
x=fixture('check-complete-fact.json');x['payload']['coverage']['files'][0]['unresolved_project_ids']=['other'];case('assigned-with-unresolved-project',x)
x=fixture('check-complete-fact.json');x['payload']['input_identity']['rechecked']=False;case('complete-with-unfinished-recheck',x)
x=fixture('check-complete-fact.json');x['payload']['input_identity']['changed_inputs']=[{'kind':'repository','path':'src/app/main.ts'}];case('complete-with-changed-source',x)
# Directory evidence may include the filesystem root outside the repository.
# Helper protocol permits file:/// for a directory; public identity must retain it.
root_location = {'kind': 'external', 'canonical_file_uri': 'file:///'}
root_inventory = {
    'kind': 'inventory', 'location': root_location,
    'presence': 'present', 'hash': 'sha256:' + 'e' * 64,
}
x = fixture('check-complete-fact.json')
x['payload']['input_identity']['inputs'].append(copy.deepcopy(root_inventory))
case('public-external-filesystem-root-inventory', x, True)

x = fixture('check-mixed-incomplete.json')
identity = x['payload']['input_identity']
identity['inputs'].append(copy.deepcopy(root_inventory))
identity['changed_inputs'].append(copy.deepcopy(root_location))
x['payload']['unknowns'][0].update(code='INPUT_CHANGED', message='Root inventory changed')
case('public-changed-external-filesystem-root-inventory', x, True)

x = fixture('check-mixed-incomplete.json')
x['payload']['input_identity']['changed_inputs'] = [copy.deepcopy(root_location)]
case('public-changed-root-without-inventory-evidence', x)

# The matching helper observation is outside file:///repo, not a fabricated path.
response = copy.deepcopy(s)
response['inputs'].append({
    'id': 'root-inventory', 'kind': 'directory',
    'observed_uri': 'file:///', 'canonical_uri': 'file:///', 'sha256': 'e' * 64,
    'symlink_hops': [],
})
assert h.validate(r, response)
for kind in ('policy', 'source', 'config', 'manifest', 'resolution', 'sdk'):
    x = fixture('check-complete-fact.json')
    x['payload']['input_identity']['inputs'].append({**root_inventory, 'kind': kind})
    case('public-filesystem-root-not-' + kind, x)
for kind in ('inventory', 'resolution'):
    x = fixture('check-mixed-incomplete.json')
    identity = x['payload']['input_identity']
    identity['inputs'].append({**root_inventory, 'kind': kind, 'presence': 'absent', 'hash': None})
    identity['changed_inputs'] = [copy.deepcopy(root_location)]
    case('public-filesystem-root-not-absent-' + kind, x)
for field in ('canonical_file_uri', 'via_path'):
    x = fixture('check-complete-fact.json')
    x['payload']['facts']['edges'][0]['resolution'][field] = 'file:///'
    case('public-edge-root-not-' + field, x)
for field in ('observed_file_uri', 'canonical_file_uri'):
    x = fixture('check-complete-fact.json')
    alias = {'observed_file_uri': 'file:///repo/a.ts', 'canonical_file_uri': 'file:///repo/b.ts'}
    alias[field] = 'file:///'
    x['payload']['input_identity']['aliases'] = [alias]
    case('public-file-alias-root-not-' + field, x)
x = fixture('check-mixed-incomplete.json')
x['payload']['input_identity']['inputs'].append({
    **root_inventory, 'location': {'kind': 'external', 'canonical_file_uri': 'file:///other'},
})
x['payload']['input_identity']['changed_inputs'] = [copy.deepcopy(root_location)]
case('public-changed-root-requires-matching-inventory-location', x)

(B/'independent/probe-results.json').write_text(json.dumps({'mutation_cases':results,'assignment_combinations_passed':assignment_cases},indent=2)+'\n')
print('FINAL:',len(results),'mutation/positive cases;',sum(x['pass'] for x in results),'PASS;',sum(not x['pass'] for x in results),'FAIL;',assignment_cases,'assignment combinations PASS')

assert all(x['pass'] for x in results), 'Independent contract regressions remain; see probe-results.json'
