"""Contract conformance tests only. Does not run or implement Archway."""
import json,pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).parent))
from entrypoint_oracle import validate_public,verify_linked
from jsonschema import Draft202012Validator
D=pathlib.Path(__file__).parent

def invariants(x):
 p=x.get('payload');cmd=x.get('command');s=x.get('status')
 if not isinstance(p,dict):return
 if cmd=='node':
  if p['mode']!='catalogue' and p['node'] is not None:
   public=p['node']['public'];assert public==sorted(set(public)),'unique sorted normalized public'
  if p['mode']=='catalogue':
   assert p['total']==len(p['nodes'])+p['omitted'],'total = returned + omitted'
   ids=[n['id'] for n in p['nodes']];assert ids==sorted(set(ids)),'unique sorted catalogue'
  if p['mode']=='path':assert (p['node'] is not None)==(p['ownership']['ownership']=='owned'),'node presence follows ownership'
 if cmd=='allows' and p['mode']=='ids' and p['from_id']==p['to_id']:assert p['policy_decision']=='allowed','same owner is allowed'
 if cmd=='allows' and p['mode']=='paths':
  a,b=p['from'],p['to']
  if a['owner_id'] is not None and a['owner_id']==b['owner_id']:assert p['policy_decision']=='allowed','same owner is allowed'
 if cmd=='allows':
  same=(p['from_id']==p['to_id']) if p['mode']=='ids' else (p['from']['owner_id'] is not None and p['from']['owner_id']==p['to']['owner_id'])
  assert (p['reason']=='same_owner')==same,'same_owner reason exactly matches ownership'
 if cmd=='init':
  assert set(p['residual_paths'])<=set(p['created_paths']),'residual subset of created'
  assert not set(p['created_paths'])&set(p['conflicting_paths']),'never create existing target'
  assert not p['dry_run'] or [f['path'] for f in p['planned_files']]==p['planned_paths'],'dry-run contains each planned file in order'
 if cmd=='check':
  o=p['observed'];c=p['coverage'];assert o['files']==len(c['files']),'corpus count'
  assert o['analyzed_files']==sum(f['analysis'] in ('complete','partial') for f in c['files']),'analyzed count'
  assert o['edges']==len(p['facts']['edges']),'edge count'
  for edge in p['facts']['edges']:
   r=edge['source_range'];assert (r['start']['line'],r['start']['column']) < (r['end']['line'],r['end']['column']),'nonempty edge span'
   assert r['path']==edge['source'],'edge range source match'
  assert o['analyzed_files']<=o['files'],'analyzed <= corpus'
  assert p['projects']==len(c['projects']),'project count'
  known={(r['project_id'],ctx['context_id']) for r in c['projects'] for ctx in r['contexts']}
  for f in c['files']:
   assert all((v['project_id'],v['context_id']) in known for v in f['candidates']),'candidate descriptor exists'
  assert all((e['project_id'],e['context_id']) in known for e in p['facts']['edges']),'edge descriptor exists'
  bypath={f['path']:f for f in c['files']}
  for e in p['facts']['edges']:
   assert e['source'] in bypath,'edge source in corpus'
   assert {'project_id':e['project_id'],'context_id':e['context_id']} in bypath[e['source']]['candidates'],'fact context must be source candidate'
  if p['policy_valid']:
   assert any(v['kind']=='policy' and v['presence']=='present' and v['hash']==x['policy_hash'] for v in p['input_identity']['inputs']),'valid policy evidence matches envelope hash'
  for f in c['files']:
   if f['assignment']=='assigned':assert f['candidates']==[{'project_id':f['project_id'],'context_id':f['context_id']}],'selected candidate'
  if p['analysis_complete']:
   assert all(f['assignment']=='assigned' and f['analysis']=='complete' for f in c['files']),'complete file coverage'
   assert all(r['status']=='complete' for r in c['projects']),'complete projects'
   assert p['input_identity']['rechecked'] and not p['input_identity']['changed_inputs'],'complete stable identity'
  if s=='incomplete':assert p['unknowns'] or p['tool_errors'],'incomplete requires reason'
  assert all(d['severity']=='warning' for d in p['warnings']),'warning severity'
  for k in ('violations','unknowns','tool_errors'):assert all(d['severity']=='error' for d in p[k]),'error severity'
 def visit(v):
  if isinstance(v,dict):
   if set(v)=={'path','start','end'}:
    assert (v['start']['line'],v['start']['column']) <= (v['end']['line'],v['end']['column']),'ordered source range'
   for y in v.values():visit(y)
  elif isinstance(v,list):
   for y in v:visit(y)
 visit(x)

def verify_export_definition_reachability(schema):
 # This self-contained schema uses direct references to top-level definitions.
 definitions=schema['$defs'];reachable=set()
 def visit(value):
  if isinstance(value,dict):
   if '$ref' in value:
    reference=value['$ref'];prefix='#/$defs/'
    assert reference.startswith(prefix),'export schema reference must be local'
    name=reference[len(prefix):]
    assert name in definitions,f'export schema dangling reference: {reference}'
    if name not in reachable:
     reachable.add(name);visit(definitions[name])
   for key,child in value.items():
    if key!='$defs':visit(child)
  elif isinstance(value,list):
   for child in value:visit(child)
 visit(schema)
 unused=set(definitions)-reachable
 assert not unused,f'export schema unreachable definitions: {sorted(unused)}'

def main():
 validators={}
 for name in ('public-result','export-diagnostics','policy'):
  s=json.loads((D/(name+'.schema.json')).read_text());Draft202012Validator.check_schema(s);validators[name]=Draft202012Validator(s)
  if name=='export-diagnostics':verify_export_definition_reachability(s)
 counts={'positive':0,'negative':0}
 for row in json.loads((D/'fixture-index.json').read_text()):
  x=json.loads((D/row['file']).read_text());err=list(validators[row['schema']].iter_errors(x))
  semantic=None
  if not err:
   try:
    if row['schema']=='policy':validate_public(x)
    else:invariants(x)
    if 'policy' in row:verify_linked(x,json.loads((D/row['policy']).read_text()))
   except AssertionError as e:semantic=str(e)
  valid=not err and semantic is None
  assert valid==row['valid'],f"{row['file']}: expected {row['valid']} errors {[e.message for e in err[:2]]} semantic {semantic}"
  counts['positive' if valid else 'negative']+=1
 print(json.dumps({'schema_draft':'2020-12','schema_meta_validation':'passed','fixtures':counts,'result':'passed'},indent=2))
if __name__=='__main__':main()
