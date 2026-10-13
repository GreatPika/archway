"""Finite, policy-only executable specification; no filesystem or compiler execution."""
import importlib.util,pathlib
B=pathlib.Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('archway_lexical',B/'compatibility/test_lexical_reference.py')
lex=importlib.util.module_from_spec(s);s.loader.exec_module(lex)
normalize=lex.normalize;matches=lex.matches

def ownership(policy,path):
 path=normalize(path)
 if any(matches(normalize(x),path) for x in policy['exclude']):return None,'excluded'
 if not any(matches(normalize(x),path) for x in policy['scope']):return None,'outside_scope'
 owners=[n['id'] for n in policy['nodes'] if any(matches(normalize(x),path) for x in n['owns'])]
 assert len(owners)<=1,'overlapping owners require prior policy rejection'
 return (owners[0],'owned') if owners else (None,'unowned')

def validate_public(policy):
 for i,node in enumerate(policy['nodes']):
  assert 'public' in node,'POLICY_SCHEMA_INVALID: /nodes/%s/public'%i
  for j,raw in enumerate(node['public']):
   pointer='/nodes/%s/public/%s'%(i,j)
   try:path=normalize(raw)
   except ValueError:raise AssertionError('POLICY_PATH_INVALID: '+pointer)
   assert not path.endswith('/') and raw.replace('\\','/').split('/')[-1] not in ('.','..'),'PUBLIC_PATH_NOT_FILE: '+pointer
   owner,state=ownership(policy,path)
   assert state!='excluded','PUBLIC_PATH_EXCLUDED: '+pointer
   assert state!='outside_scope','PUBLIC_PATH_OUTSIDE_SCOPE: '+pointer
   assert owner==node['id'],'PUBLIC_PATH_NOT_OWNED: '+pointer

def decide(policy,source,target,mode='paths'):
 nodes={n['id']:n for n in policy['nodes']}
 if mode=='ids':
  assert source in nodes and target in nodes,'UNKNOWN_NODE_ID'
  a,b=source,target
 else:
  assert all(x.replace('\\','/').split('/')[-1] not in ('.','..') for x in (source,target)),'USAGE_ERROR'
  source,target=normalize(source),normalize(target)
  assert not source.endswith('/') and not target.endswith('/'),'USAGE_ERROR'
  a,_=ownership(policy,source);b,_=ownership(policy,target)
  if a is None or b is None:return 'undetermined','ownership_unknown'
 if a==b:return 'allowed','same_owner'
 if b not in nodes[a]['allows']:return 'denied','not_allowed'
 if mode=='paths' and target not in {normalize(x) for x in nodes[b]['public']}:return 'denied','target_not_public'
 return 'allowed','declared_allow'

def edge_violation(policy,edge):
 # Only a resolved, known local edge is eligible for a boundary decision.
 resolution=edge['resolution']
 if resolution['kind']!='local':return None
 target=resolution['path']
 if target is None:return 'LOCAL_TARGET_OUTSIDE_SCOPE'
 _,state=ownership(policy,target)
 if state!='owned':return {'excluded':'LOCAL_TARGET_EXCLUDED','outside_scope':'LOCAL_TARGET_OUTSIDE_SCOPE','unowned':'LOCAL_TARGET_UNOWNED'}[state]
 source_owner,_=ownership(policy,edge['source'])
 # SOURCE_UNOWNED is a separate file-level diagnostic, not duplicated per edge.
 if source_owner is None:return None
 decision,reason=decide(policy,edge['source'],target)
 return {'not_allowed':'DEPENDENCY_NOT_ALLOWED','target_not_public':'TARGET_NOT_PUBLIC'}.get(reason)

def verify_linked(result,policy):
 validate_public(policy)
 p=result['payload']
 if result['command']=='allows':
  mode=p['mode'];a,b=(p['from_id'],p['to_id']) if mode=='ids' else (p['from']['path'],p['to']['path'])
  assert (p['policy_decision'],p['reason'])==decide(policy,a,b,mode),'decision differs from linked policy'
  if mode=='paths':
   for side in ('from','to'):
    owner,state=ownership(policy,p[side]['path'])
    assert (p[side]['owner_id'],p[side]['ownership'])==(owner,state),'ownership differs from linked policy'
 if result['command']=='check':
  # This finite linked-fixture oracle covers owned source files only. File-level
  # SOURCE_UNOWNED, discovery and compiler diagnostics are outside its comparison.
  assert all(ownership(policy,e['source'])[0] is not None for e in p['facts']['edges']),'linked fixture requires owned sources'
  expected=[]
  for e in p['facts']['edges']:
   code=edge_violation(policy,e)
   if not code:continue
   pointer=None
   if code in ('TARGET_NOT_PUBLIC','DEPENDENCY_NOT_ALLOWED'):
    path=e['resolution']['path'] if code=='TARGET_NOT_PUBLIC' else e['source']
    owner,_=ownership(policy,path)
    index=next(i for i,n in enumerate(policy['nodes']) if n['id']==owner)
    pointer='/nodes/%s/%s'%(index,'public' if code=='TARGET_NOT_PUBLIC' else 'allows')
   expected.append((code,pointer,e['source'],e['source_range'],e['project_id']))
  actual=[(d['code'],d['rule_pointer'],d['path'],d['source_range'],d['project_id']) for d in p['violations']]
  import json
  key=lambda x:json.dumps(x,sort_keys=True)
  assert sorted(actual,key=key)==sorted(expected,key=key),'diagnostic evidence differs from linked resolved-edge policy'
