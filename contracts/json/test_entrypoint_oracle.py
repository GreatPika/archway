"""Design-model tests only; not CLI, analyzer, or filesystem integration tests."""
import copy,json,pathlib,unittest
from entrypoint_oracle import validate_public,decide,edge_violation,normalize
D=pathlib.Path(__file__).parent
class PublicBoundary(unittest.TestCase):
 def setUp(self):self.p=json.loads((D/'fixtures/policy-entrypoints.json').read_text())
 def test_cross_owner_truth_table(self):
  for allowed in (False,True):
   for public in (False,True):
    with self.subTest(allowed=allowed,public=public):
     p=copy.deepcopy(self.p);p['nodes'][0]['allows']=['pricing'] if allowed else [];p['nodes'][1]['public']=['src/pricing/x.ts'] if public else []
     expected=('denied','not_allowed') if not allowed else ('allowed','declared_allow') if public else ('denied','target_not_public')
     self.assertEqual(decide(p,'src/app/main.ts','src/pricing/x.ts'),expected)
     self.assertEqual(decide(p,'app','pricing','ids'),('allowed','declared_allow') if allowed else ('denied','not_allowed'))
 def test_same_owner_always(self):
  for public in ([],['src/pricing/index.ts']):
   self.p['nodes'][1]['public']=public
   self.assertEqual(decide(self.p,'src/pricing/private.ts','src/pricing/other.ts'),('allowed','same_owner'))
 def test_no_transitive_permission(self):
  self.p['nodes'].append({'id':'third','responsibility':'Third','owns':['src/third/'],'allows':[],'public':['src/third/api.ts']})
  self.p['nodes'][1]['allows']=['third']
  self.assertEqual(decide(self.p,'src/app/a.ts','src/third/api.ts'),('denied','not_allowed'))
 def test_lexical_normalization_and_exactness(self):
  self.p['nodes'][1]['public']=[r'src\pricing\index.ts','./src/pricing/a/../index.ts','src/pricing/index.ts']
  validate_public(self.p)
  self.assertEqual({normalize(x) for x in self.p['nodes'][1]['public']},{'src/pricing/index.ts'})
  self.assertEqual(decide(self.p,'src/app/a.ts','src/pricing/index.ts'),('allowed','declared_allow'))
  for target in ['src/pricing/index.ts/child','src/pricing/Index.ts','src/pricing/internal.ts']:
   self.assertEqual(decide(self.p,'src/app/a.ts',target),('denied','target_not_public'))
 def test_public_validation_diagnostics(self):
  for raw,code in [('src/pricing/', 'PUBLIC_PATH_NOT_FILE'),('src\\pricing\\','PUBLIC_PATH_NOT_FILE'),('.', 'PUBLIC_PATH_NOT_FILE'),('src/pricing/index.ts/.','PUBLIC_PATH_NOT_FILE'),('src/pricing/index.ts/dir/..','PUBLIC_PATH_NOT_FILE'),('src/pricing/generated/api.ts','PUBLIC_PATH_EXCLUDED'),('docs/api.ts','PUBLIC_PATH_OUTSIDE_SCOPE'),('src/app/main.ts','PUBLIC_PATH_NOT_OWNED'),('src/unowned.ts','PUBLIC_PATH_NOT_OWNED'),('../x','POLICY_PATH_INVALID')]:
   with self.subTest(raw=raw):
    p=copy.deepcopy(self.p);p['nodes'][1]['public']=[raw]
    with self.assertRaisesRegex(AssertionError,code+': /nodes/1/public/0'):validate_public(p)
 def test_path_query_usage(self):
  for path in ['src/pricing/','src\\pricing\\','.','src/pricing/x.ts/.','src/pricing/x.ts/a/..']:
   for a,b in [(path,'src/app/a.ts'),('src/app/a.ts',path)]:
    with self.assertRaisesRegex(AssertionError,'USAGE_ERROR'):decide(self.p,a,b)
 def test_planned_mixed_language_and_data_files(self):
  for path in ['dart/lib/pricing.dart','src/pricing/index.ts','src/pricing/future.xyz','src/pricing/API']:
   self.p['nodes'][1]['public']=[path];validate_public(self.p)
   self.assertEqual(decide(self.p,'src/app/a.ts',path),('allowed','declared_allow'))
 def test_edge_kinds_are_uniform(self):
  for kind in ['import','export','import_type','require','dynamic_import','part','part_of']:
   edge={'source':'src/app/a.ts','kind':kind,'resolution':{'kind':'local','path':'src/pricing/internal.ts'}}
   self.assertEqual(edge_violation(self.p,edge),'TARGET_NOT_PUBLIC')
   edge['source']='src/pricing/index.ts';self.assertIsNone(edge_violation(self.p,edge))
 def test_nonlocal_resolution_not_subject_to_public(self):
  for kind in ['external','builtin','unresolved']:
   self.assertIsNone(edge_violation(self.p,{'resolution':{'kind':kind}}))
 def test_target_classification_precedence(self):
  for path,code in [(None,'LOCAL_TARGET_OUTSIDE_SCOPE'),('docs/api.ts','LOCAL_TARGET_OUTSIDE_SCOPE'),('src/pricing/generated/api.ts','LOCAL_TARGET_EXCLUDED'),('src/free.ts','LOCAL_TARGET_UNOWNED')]:
   self.assertEqual(edge_violation(self.p,{'source':'src/app/a.ts','resolution':{'kind':'local','path':path}}),code)
 def test_unknown_source_preserves_target_classification(self):
  for path,code in [(None,'LOCAL_TARGET_OUTSIDE_SCOPE'),('src/pricing/generated/api.ts','LOCAL_TARGET_EXCLUDED'),('src/free.ts','LOCAL_TARGET_UNOWNED'),('src/pricing/internal.ts',None)]:
   self.assertEqual(edge_violation(self.p,{'source':'src/free-source.ts','resolution':{'kind':'local','path':path}}),code)
if __name__=='__main__':unittest.main(verbosity=2)
