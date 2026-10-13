"""Maintainer-only offline preparation, separate from AOT checks."""
import os, subprocess, sys
from pathlib import Path
base, dart = map(Path, sys.argv[1:3])
def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
def prepare(root):
    result = subprocess.run([str(dart), '--suppress-analytics', 'pub', 'get', '--offline'], cwd=root, capture_output=True, text=True, timeout=90)
    write(root / 'preparation.log', result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
spec = 'name: fixture\nenvironment:\n  sdk: ^3.13.0\n'
write(base/'hosted/pubspec.yaml', spec+'dependencies:\n  collection: 1.19.1\n')
prepare(base/'hosted')
write(base/'outside/pubspec.yaml', 'name: outside_pkg\nversion: 1.2.3\nenvironment:\n  sdk: ^3.13.0\n')
write(base/'outside/lib/value.dart', 'class Value {}\n')
write(base/'path/pubspec.yaml', spec+'dependencies:\n  outside_pkg:\n    path: ../outside\n')
prepare(base/'path')
write(base/'workspace/pubspec.yaml', 'name: workspace_root\nenvironment:\n  sdk: ^3.13.0\nworkspace: [packages/app, packages/core]\n')
for name in ['app', 'core']:
    write(base/f'workspace/packages/{name}/pubspec.yaml', f'name: {name}\nversion: 1.0.0\nresolution: workspace\nenvironment:\n  sdk: ^3.13.0\n'+('dependencies:\n  core: ^1.0.0\n' if name == 'app' else ''))
write(base/'workspace/packages/core/lib/value.dart', 'class Value {}\n')
prepare(base/'workspace')
print('Three real offline pub fixtures prepared; no CLI checks performed.')
