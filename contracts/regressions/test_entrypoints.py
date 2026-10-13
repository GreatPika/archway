"""Finite entrypoint adversarial specification checks; no compilers/filesystem probes."""
import copy, importlib.util, json, pathlib, sys
from jsonschema import Draft202012Validator
B=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(B/'json'))
import entrypoint_oracle as oracle
import verify_contract as contract
P=json.loads((B/'json/fixtures/policy-entrypoints.json').read_text())
PV=Draft202012Validator(json.loads((B/'json/policy.schema.json').read_text()))
RV=Draft202012Validator(json.loads((B/'json/public-result.schema.json').read_text()))
results=[]
def record(name,actual,expected):results.append(dict(case=name,actual=actual,expected=expected,passed=actual==expected))
def accepted_policy(p):
 try:PV.validate(p);oracle.validate_public(p);return True
 except (AssertionError,ValueError,TypeError,KeyError):return False
 except Exception as e:
  if e.__class__.__name__=='ValidationError':return False
  raise

def public_case(name,value,expected):
 p=copy.deepcopy(P);p['nodes'][1]['public']=value;record(name,accepted_policy(p),expected)

def decision(name,s,t,want,p=None,mode='paths'):
 try:actual=list(oracle.decide(p or P,s,t,mode))
 except (AssertionError,ValueError):actual='invalid'
 record(name,actual,want)

def linked(name,result,p,expected):
 try:RV.validate(result);contract.invariants(result);oracle.verify_linked(result,p);actual=True
 except (AssertionError,ValueError,TypeError,KeyError):actual=False
 except Exception as e:
  if e.__class__.__name__=='ValidationError':actual=False
  else:raise
 record(name,actual,expected)

def fixture(name):return json.loads((B/'json/fixtures'/name).read_text())

for value in [None,{},'src/pricing/index.ts',5,False,[None],[3],[{}]]:public_case('malformed-public-'+repr(value),value,False)
p=copy.deepcopy(P);del p['nodes'][1]['public'];record('required-public',accepted_policy(p),False)
for raw in ['.','./','src/pricing/','src/pricing\\','src/pricing/.','src/pricing/x/..','src/pricing/x/../','src/pricing/*.ts','/src/pricing/index.ts','../index.ts','src/app/main.ts','src/pricing/generated/api.ts','other/index.ts','src/unowned.ts']:
 public_case('public-invalid-'+raw,[raw],False)
for raw in ['src/pricing/future.ts','src/pricing/extensionless','src/pricing/./index.ts','src/pricing/x/../index.ts','src\\pricing\\index.ts','src/pricing/e\u0301.ts']:
 public_case('public-valid-'+raw,[raw],True)
public_case('duplicate-normalized-public',['src/pricing/index.ts','src/pricing/./index.ts'],True)
public_case('exact-prefix-files-not-subsumed',['src/pricing/api','src/pricing/api.ts'],True)
for raw in ['.','./','src/pricing/','src/pricing\\','src/pricing/.','src/pricing/x/..','src/pricing/x/../']:
 decision('query-directory-target-'+raw,'src/app/main.ts',raw,'invalid')
 decision('query-directory-source-'+raw,raw,'src/pricing/index.ts','invalid')
decision('same-owner-private','src/pricing/a.ts','src/pricing/b.ts',['allowed','same_owner'])
decision('public-target','src/app/main.ts','src/pricing/index.ts',['allowed','declared_allow'])
decision('private-deep-import','src/app/main.ts','src/pricing/internal.ts',['denied','target_not_public'])
decision('public-prefix-not-directory','src/app/main.ts','src/pricing/index.ts/child.ts',['denied','target_not_public'])
decision('excluded-target','src/app/main.ts','src/pricing/generated/api.ts',['undetermined','ownership_unknown'])
decision('unowned-source','src/orphan.ts','src/pricing/index.ts',['undetermined','ownership_unknown'])
decision('outside-target','src/app/main.ts','outside.ts',['undetermined','ownership_unknown'])
p=copy.deepcopy(P);p['nodes'][0]['allows']=[]
decision('graph-denied-beats-private','src/app/main.ts','src/pricing/internal.ts',['denied','not_allowed'],p)
p=copy.deepcopy(P);p['nodes'][1]['public']=[]
decision('ids-empty-public-still-allowed','app','pricing',['allowed','declared_allow'],p,'ids')
decision('files-empty-public-denied','src/app/main.ts','src/pricing/index.ts',['denied','target_not_public'],p)
p=copy.deepcopy(P);p['nodes'][1]['public']=['src/pricing/source.ts']
decision('redirect-to-private-dts-source-public-insufficient','src/app/main.ts','src/pricing/source.d.ts',['denied','target_not_public'],p)
p['nodes'][1]['public'].append('src/pricing/source.d.ts')
decision('redirect-to-public-dts','src/app/main.ts','src/pricing/source.d.ts',['allowed','declared_allow'],p)
p=copy.deepcopy(P);p['nodes'].append({'id':'core','responsibility':'Core','owns':['src/core/'],'allows':[],'public':['src/core/index.ts']});p['nodes'][1]['allows']=['core']
for name,s,t,w in [
 ('facade-A-to-B','src/app/main.ts','src/pricing/index.ts',['allowed','declared_allow']),
 ('facade-B-to-C','src/pricing/index.ts','src/core/index.ts',['allowed','declared_allow']),
 ('facade-no-transitive-A-to-C','src/app/main.ts','src/core/index.ts',['denied','not_allowed']),
 ('facade-C-public-to-private','src/core/index.ts','src/core/private.ts',['allowed','same_owner']),
 ('facade-B-direct-C-private','src/pricing/index.ts','src/core/private.ts',['denied','target_not_public'])]:decision(name,s,t,w,p)
# Mutation checks link visible results to the policy that produced them.
x=fixture('allows-public-entrypoint.json');linked('linked-public-baseline',x,P,True)
p=copy.deepcopy(P);p['nodes'][1]['public']=[];linked('mutated-public-cannot-preserve-allowed-query',x,p,False)
p=copy.deepcopy(P);p['nodes'][0]['allows']=[];linked('mutated-allows-cannot-preserve-allowed-query',x,p,False)
x=fixture('allows-public-entrypoint.json');x['payload']['decision_scope']='module';linked('file-query-cannot-claim-module-scope',x,P,False)
x=fixture('allows-public-entrypoint.json');x['payload']['reason']='same_owner';linked('file-query-false-same-owner-reason',x,P,False)
x=fixture('check-public-import.json');linked('linked-check-public-baseline',x,P,True)
p=copy.deepcopy(P);p['nodes'][1]['public']=[];linked('mutated-public-cannot-preserve-successful-check',x,p,False)
x=fixture('check-public-import.json');edge=x['payload']['facts']['edges'][0];edge['resolution']['path']='src/pricing/private.d.ts';edge['resolution']['canonical_file_uri']='file:///repo/src/pricing/private.d.ts';linked('redirected-private-dts-cannot-preserve-successful-check',x,P,False)
# Keep physical part source ownership, not its containing library owner.
decision('dart-physical-source-cross-owner','dart/lib/pricing/part.dart','src/app/main.ts',['denied','not_allowed'])
decision('dart-public-library-same-owner-private-part','dart/lib/pricing.dart','dart/lib/pricing/part.dart',['allowed','same_owner'])
# Classification is trusted adapter evidence at this layer, never inferred from spelling,
# root containment, broad owns, or Program membership. These do not test compiler provenance.
record('bare-package-spelling-cannot-bypass-confirmed-local',oracle.edge_violation(P,{'source':'src/app/main.ts','specifier':'pricing/internal','resolution':{'kind':'local','path':'src/pricing/internal.ts'}}),'TARGET_NOT_PUBLIC')
for kind in ('external','builtin'):
 record('proven-'+kind+'-outside-public-rule',oracle.edge_violation(P,{'source':'src/app/main.ts','resolution':{'kind':kind,'identity':'verified:example'}}),None)
# Diagnostic provenance must name the target policy field while retaining importing source evidence.
for field,value in [('rule_pointer','/nodes/0/public'),('path','src/pricing/internal.ts'),('project_id','wrong-project')]:
 x=fixture('check-private-import.json');x['payload']['violations'][0][field]=value
 linked('private-diagnostic-mutated-'+field,x,P,False)
x=fixture('check-private-import.json');x['payload']['violations'][0]['source_range']['start']['column']=2
linked('private-diagnostic-mutated-source-span',x,P,False)
x=fixture('check-private-import.json');x['payload']['violations'].append(copy.deepcopy(x['payload']['violations'][0]))
linked('private-diagnostic-duplicated',x,P,False)
x=fixture('check-private-import.json');x['payload']['violations'][0]['code']='DEPENDENCY_NOT_ALLOWED'
linked('private-diagnostic-wrong-principal-failure',x,P,False)
# Source diagnostics and target diagnostics must coexist; the edge predicate must retain target classification.
for target,want in [('src/pricing/generated/x.ts','LOCAL_TARGET_EXCLUDED'),('outside/x.ts','LOCAL_TARGET_OUTSIDE_SCOPE'),('src/orphan.ts','LOCAL_TARGET_UNOWNED')]:
 e={'source':'src/missing-owner.ts','resolution':{'kind':'local','path':target}}
 record('target-classification-survives-unowned-source-'+target,oracle.edge_violation(P,e),want)
report={'description':'Finite entrypoint contract tests. No Archway implementation or compiler certification.','tests':results,'passed':sum(r['passed'] for r in results),'failed':sum(not r['passed'] for r in results)}
print(json.dumps({k:report[k] for k in ['passed','failed']}))
for r in results:
 if not r['passed']:print(json.dumps(r))
assert report['failed']==0,'Entrypoint counterexamples remain'
