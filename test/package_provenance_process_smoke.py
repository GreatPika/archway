"""Bounded real AOT package provenance. No installs, builds, hooks or network.
Args: executable, repository, prepared pub directory, prepared Git fixture, output.
The caller supplies pinned Dart/Node in PATH. Host proof, not release certification.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from jsonschema import Draft202012Validator
from node_package_fixture_support import extract_node_fixture
from process_fixture_support import file_uri_path

executable, repo, pub, git, output = [Path(v).resolve() for v in sys.argv[1:6]]
output.mkdir(parents=True, exist_ok=True)
fixtures = output / 'fixtures'
fixtures.mkdir()
schema = Draft202012Validator(json.loads((repo / 'contracts/json/public-result.schema.json').read_text()))
results = []

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def policy(adapter, directory, package_roots='./'):
    config = 'tsconfig: tsconfig.json' if adapter == 'typescript' else f'package_roots: [{package_roots}]'
    return f'''version: 1
projects:
  - {{id: app, adapter: {adapter}, {config}}}
scope: [{directory}/]
exclude: []
nodes:
  - {{id: app, responsibility: App, owns: [{directory}/app/], allows: [], public: []}}
  - {{id: core, responsibility: Core, owns: [{directory}/core/], allows: [], public: []}}
'''

def snapshot(root):
    return {str(p.relative_to(root)): ('link:' + os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest())
            for p in root.rglob('*') if p.is_symlink() or p.is_file()}

def invoke(name, root, expected_kind, specifier, code=1, violation='DEPENDENCY_NOT_ALLOWED', identity=None):
    before = snapshot(root)
    result = subprocess.run([str(executable), '--root', str(root), 'check'], cwd=output,
                            capture_output=True, timeout=90)
    (output / (name + '.stdout.json')).write_bytes(result.stdout)
    (output / (name + '.stderr.txt')).write_bytes(result.stderr)
    assert result.returncode == code, (name, result.returncode, result.stdout, result.stderr)
    assert result.stderr == b'', (name, result.stderr)
    assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1, name
    value = json.loads(result.stdout)
    schema.validate(value)
    assert value['exit_code'] == code, name
    assert value['status'] == {0: 'ok', 1: 'negative', 2: 'incomplete'}[code], name
    payload = value['payload']
    assert payload['input_identity']['rechecked'], name
    assert payload['analysis_complete'] == (code != 2), name
    assert payload['tool_errors'] == [], (name, payload['tool_errors'])
    edge = next(e for e in payload['facts']['edges'] if e['specifier'] == specifier)
    assert edge['resolution']['kind'] == expected_kind, (name, edge)
    if identity:
        assert edge['resolution']['identity'] == identity, (name, edge)
    codes = [v['code'] for v in payload['violations']]
    if violation:
        assert violation in codes, (name, codes)
        assert 'DEPENDENCY_NOT_ALLOWED' in codes, (name, codes)
    else:
        assert codes == [], (name, codes)
    if code == 2:
        assert payload['unknowns'], name
        assert any(e['resolution']['kind'] == 'local' for e in payload['facts']['edges']), name
    assert before == snapshot(root), f'{name}: check wrote project inputs'
    results.append({'case': name, 'exit': code, 'status': value['status'], 'kind': expected_kind,
                    'violations': codes, 'unknowns': [u['code'] for u in payload['unknowns']]})
    print(f'PASS {name}: exit={code} kind={expected_kind}', flush=True)
    (output/'summary.json').write_text(json.dumps(results, indent=2)+'\n')
    return value

# These are genuine prepared manager outputs. Preserve all sibling/link topology.
node = fixtures/'node'
node.mkdir()
for archive in ['prepared.tar.gz', 'addon.tar.gz']:
    extract_node_fixture(repo/'test/fixtures/node-packages'/archive, node)

def ts(name, specifier, independent=True):
    root = node/name
    shutil.rmtree(root/'src', ignore_errors=True)
    write(root/'architecture.yaml', policy('typescript', 'src'))
    write(root/'src/app/main.ts', f"import '{specifier}';\n"+("import '../core/private.js';\n" if independent else ''))
    write(root/'src/core/private.ts', 'export const value = 1;\n')
    return root

for name, specifier, kind, identity in [
    ('npm-v3-small', 'ansi-regex', 'external', 'npm:ansi-regex@6.1.0'),
    ('pnpm-registry', 'ansi-regex', 'external', 'pnpm:ansi-regex@6.1.0'),
    ('npm-tarball', 'ansi-regex', 'external', 'npm:ansi-regex@6.1.0'),
    ('pnpm-git', 'ansi-regex', 'external', None),
    ('pnpm-peer', 'react-dom/client', 'external', 'pnpm:@types/react-dom@19.0.4(@types/react@19.0.12)'),
    ('npm-workspace', 'archway-local-types', 'local', None),
    ('pnpm-injected', 'archway-local-types', 'local', None),
    ('npm-file', 'archway-outside-types', 'local', None),
    ('npm-path', 'archway-outside-types', 'local', None),
    ('pnpm-path', 'archway-outside-types', 'local', None),
]:
    root = ts(name, specifier)
    value = invoke(name, root, kind, specifier, identity=identity)
    if name.endswith('-path'):
        assert any(v['code'] == 'LOCAL_TARGET_OUTSIDE_SCOPE' for v in value['payload']['violations']), name
        assert next(e for e in value['payload']['facts']['edges'] if e['specifier'] == specifier)['resolution']['path'] is None

root = ts('npm-v2', 'ansi-regex', independent=False)
invoke('npm-clean-success', root, 'external', 'ansi-regex', code=0, violation=None)
root = ts('npm-shrinkwrap', 'ansi-regex')
write(root/'package-lock.json', '{"lockfileVersion": 99}')
invoke('npm-shrinkwrap-precedence', root, 'external', 'ansi-regex')
root = node/'pnpm-registry'
saved = {name: (root/name).read_bytes() for name in ['package.json', 'pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']}
source = 'https://registry.npmjs.org/ansi-regex/-/ansi-regex-6.1.0.tgz'
manifest = json.loads((root/'package.json').read_text())
manifest['dependencies']['ansi-regex'] = source
write(root/'package.json', json.dumps(manifest))
for name in ['pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']:
    lock = root/name
    lock.write_text(lock.read_text().replace('specifier: 6.1.0', f'specifier: "{source}"', 1).replace(
        'resolution: {integrity:', 'resolution: {tarball: "https://example.org/contradictory.tgz", integrity:', 1))
invoke('pnpm-explicit-tarball-conflict', root, 'unresolved', 'ansi-regex', code=2)
for name, content in saved.items():
    (root/name).write_bytes(content)
for name, lock in [('npm-v3-small', 'package-lock.json'), ('pnpm-registry', 'pnpm-lock.yaml')]:
    root = node/name
    (root/lock).unlink()
    invoke(name+'-missing-lock', root, 'unresolved', 'ansi-regex', code=2)
for name in ['npm-alias', 'pnpm-alias']:
    root = ts(name, 'fixture-alias')
    manifest = root/'node_modules/fixture-alias/package.json'
    # Replace a copied installed file, including hardlinks, before writing.
    value = json.loads(manifest.read_text())
    value['name'] = 'contradictory-name'
    manifest.unlink()
    write(manifest, json.dumps(value))
    invoke(name+'-conflict', root, 'unresolved', 'fixture-alias', code=2)

# Pub fixtures were generated by a separate, logged offline preparation step.
shutil.copytree(pub, fixtures/'pub', symlinks=True)
def dart(name, specifier):
    root = fixtures/'pub'/name
    write(root/'architecture.yaml', policy('dart', 'lib'))
    write(root/'lib/app/main.dart', f"import '{specifier}';\nimport '../core/private.dart';\nimport 'dart:io';\n")
    write(root/'lib/core/private.dart', 'class Value {}\n')
    return root

root = dart('hosted', 'package:collection/collection.dart')
invoke('pub-hosted', root, 'external', 'package:collection/collection.dart')
shutil.copytree(root, fixtures/'pub/hosted-inside', symlinks=True)
inside = fixtures/'pub/hosted-inside'
config = json.loads((inside/'.dart_tool/package_config.json').read_text())
entry = next(e for e in config['packages'] if e['name'] == 'collection')
original = Path(file_uri_path(entry['rootUri']))
shutil.copytree(original, inside/'lib/app/vendor/collection', symlinks=True)
for options in (inside/'lib/app/vendor/collection').rglob('analysis_options.yaml'):
    options.write_text('{}')
entry['rootUri'] = '../lib/app/vendor/collection/'
write(inside/'.dart_tool/package_config.json', json.dumps(config))
write(inside/'architecture.yaml', policy('dart', 'lib').replace('exclude: []', 'exclude: [lib/app/vendor/]'))
invoke('pub-hosted-inside-root', inside, 'external', 'package:collection/collection.dart')
original_spec = (root/'pubspec.yaml').read_text()
write(root/'pubspec.yaml', original_spec.replace('collection: 1.19.1', 'collection: ^2.0.0'))
invoke('pub-version-conflict', root, 'unresolved', 'package:collection/collection.dart', code=2)
write(root/'pubspec.yaml', original_spec)
(root/'pubspec.lock').unlink()
invoke('pub-missing-lock', root, 'unresolved', 'package:collection/collection.dart', code=2)
root = dart('path', 'package:outside_pkg/value.dart')
invoke('pub-outside-path', root, 'local', 'package:outside_pkg/value.dart', violation='LOCAL_TARGET_OUTSIDE_SCOPE')
root = fixtures/'pub/workspace'
write(root/'architecture.yaml', policy('dart', 'packages', 'packages/app, packages/core'))
write(root/'packages/app/lib/main.dart', "import 'package:core/value.dart';\n")
invoke('pub-workspace-hosted-constraint', root, 'local', 'package:core/value.dart')
shutil.copytree(git, fixtures/'pub/git', symlinks=True)
root = dart('git', 'package:path/path.dart')
invoke('pub-pinned-git', root, 'external', 'package:path/path.dart')
print(f'{len(results)} package provenance AOT process checks passed; host-only evidence.')
