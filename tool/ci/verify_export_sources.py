"""Fail before export builds if copied tracked sources differ from Git blobs."""
from pathlib import Path
import subprocess
import sys


def git(*args):
    return subprocess.check_output(['git', *args])


commit = git('rev-parse', 'HEAD').decode().strip()
if commit != sys.argv[1]:
    raise ValueError('Checkout commit differs from the workflow source commit')
names = git('ls-files', '-z', 'assets/typescript', 'pubspec.lock').decode().split('\0')
for name in filter(None, names):
    path = Path(name)
    if (name == 'pubspec.lock' or name.startswith('assets/typescript/licenses/')
            or (path.parent == Path('assets/typescript')
                and path.suffix in ('.cjs', '.json', '.md'))):
        if path.read_bytes() != git('cat-file', 'blob', f'{commit}:{name}'):
            raise ValueError(f'Export source bytes differ from Git: {name}')
print(f'Copied tracked assets and lockfiles match Git blobs at {commit}')
