"""Executable specification model only; not Archway implementation/OS certification."""
import re
import unicodedata
import unittest

def normalize(raw):
    if not isinstance(raw,str) or not raw:
        raise ValueError('empty')
    s=unicodedata.normalize('NFC', raw.replace('\\','/'))
    if s.startswith('/') or re.match(r'^[A-Za-z]:',s):
        raise ValueError('absolute')
    if any(ord(c)<32 or ord(c)==127 or c in ':*?"<>|[]{}' for c in s):
        raise ValueError('reserved')
    stack=[]
    for part in s.split('/'):
        if part in ('','.'): continue
        if part=='..':
            if not stack: raise ValueError('escape')
            stack.pop(); continue
        if part.endswith((' ','.')): raise ValueError('trailing')
        if re.fullmatch(r'(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])',part.split('.')[0],re.I):
            raise ValueError('device')
        stack.append(part)
    if not stack:return './'
    return '/'.join(stack)+('/' if s.endswith('/') else '')

def matches(pattern,path):
    return pattern=='./' or (path.startswith(pattern) if pattern.endswith('/') else path==pattern)

class LexicalReference(unittest.TestCase):
    def test_normalization(self):
        examples={r'src\a.ts':'src/a.ts','./src//x/../a.ts':'src/a.ts','a/..':'./','.':'./','./':'./', 'src/':'src/','src':'src','src/%2e%2e/a.ts':'src/%2e%2e/a.ts','src/e\u0301.ts':'src/é.ts','a/../b':'b','a\\b\\':'a/b/'}
        for source,target in examples.items():
            with self.subTest(source=source): self.assertEqual(normalize(source),target)
    def test_invalid(self):
        for value in ['', '../repo/a.ts','a/../../b','/src/a',r'C:\a','C:a',r'\\server\share\x',r'\\?\C:\x','src/CON.ts','src/lpt1','src/a.ts:secret','a/evil.','a/b ','a/\x00b','a/\x7fb','a/*.ts','https://a/b','src/[a].ts','src/{a}.ts']:
            with self.subTest(source=value):self.assertRaises(ValueError,normalize,value)
    def test_matching(self):
        self.assertTrue(matches('src/','src/a.ts'))
        self.assertFalse(matches('src/','src2/a.ts'))
        self.assertFalse(matches('src','src/a.ts'))
        self.assertTrue(matches('./','src/a.ts'))
        self.assertFalse(matches('src/Foo.ts','src/foo.ts'))
    def test_idempotent(self):
        for s in ['.','a/..','src\\a.ts','./a//b/../c/','src/e\u0301.ts']:
            self.assertEqual(normalize(normalize(s)),normalize(s))

if __name__=='__main__': unittest.main(verbosity=2)
