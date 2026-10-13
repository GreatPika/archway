"""Real relocated native AOT asset loading; read-only commands need no bridge."""
import json
import os
from pathlib import Path
import shutil
from installation_staging import stage_installation
from native_process_support import native_target, build_library
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repo = Path(__file__).resolve().parents[1]
executable = Path(sys.argv[1]).resolve()
public = Draft202012Validator(json.loads((repo / 'contracts/json/public-result.schema.json').read_text()))
export = Draft202012Validator(json.loads((repo / 'contracts/json/export-diagnostics.schema.json').read_text()))
target, library, source_name = native_target()
executable_name = 'archway.exe' if target == 'windows-x64' else 'archway'
assert executable.parts[-3:] == ('bin', target, executable_name)
count = 0
with tempfile.TemporaryDirectory(prefix='archway-native-assets-') as temp:
    base = Path(temp).resolve()
    bundle = base / 'relocated café bundle'
    binary = stage_installation(executable, bundle)
    asset = bundle / 'native' / target / library
    cwd = base / 'unrelated cwd'
    (cwd / 'native').mkdir(parents=True)
    (cwd / 'native' / library).write_text('Do not load assets from cwd')
    root = base / 'project'
    root.mkdir()

    def invoke(args, expected):
        global count
        result = subprocess.run([str(binary), '--root', str(root), *args], cwd=cwd,
                                env={**os.environ, 'PATH': '/no-runtime-here'},
                                capture_output=True, timeout=10)
        assert result.returncode == expected, (args, result)
        if args[0] == 'export':
            if expected:
                assert result.stdout == b''
            if result.stderr:
                export.validate(json.loads(result.stderr))
        else:
            assert result.stderr == b''
            public.validate(json.loads(result.stdout))
        count += 1
        return result

    invoke(['init', '--template', 'mixed'], 0)
    invoke(['export', '--format', 'mermaid', '--out', 'valid.mmd'], 0)
    assert (root / 'valid.mmd').read_text().endswith('flowchart LR\n')
    # Both direct and ancestor aliases must fail immediately before loading.
    original = asset.rename(asset.with_name('original' + asset.suffix))
    asset.symlink_to(original)
    invoke(['export', '--format', 'mermaid', '--out', 'aliased.mmd'], 2)
    assert not (root / 'aliased.mmd').exists()
    asset.unlink()
    original.rename(asset)
    original_parent = asset.parent.rename(bundle / 'real-native')
    asset.parent.symlink_to(original_parent, target_is_directory=True)
    invoke(['export', '--format', 'mermaid', '--out', 'aliased-parent.mmd'], 2)
    assert not (root / 'aliased-parent.mmd').exists()
    asset.parent.unlink()
    original_parent.rename(asset.parent)
    asset.unlink()
    invoke(['validate'], 0)
    invoke(['node'], 0)
    invoke(['export', '--format', 'mermaid'], 0)
    missing = invoke(['export', '--format', 'mermaid', '--out', 'missing.mmd'], 2)
    assert not (root / 'missing.mmd').exists()
    assert json.loads(missing.stderr)['diagnostics'][-1]['code'] == 'EXPORT_WRITE_FAILED'
    (root / 'architecture.yaml').unlink()
    (root / 'ARCHITECTURE_AGENT.md').unlink()
    invoke(['init', '--template', 'mixed', '--dry-run'], 0)
    missing_init = invoke(['init', '--template', 'mixed'], 2)
    assert json.loads(missing_init.stdout)['diagnostics'][0]['code'] == 'INIT_UNAVAILABLE'
    assert not (root / 'architecture.yaml').exists()

    # Same ABI layout/symbols, rejected version: do not enter unsafe operations.
    wrong_source = base / 'wrong_version.c'
    source = (repo / 'native' / source_name).read_text()
    version = 'archway_io_version(void) { return 2; }'
    assert source.count(version) == 1, 'Expected exactly one ABI version definition'
    wrong_source.write_text(source.replace(
        version, 'archway_io_version(void) { return 1; }'))
    build_library(wrong_source, asset)
    wrong_init = invoke(['init', '--template', 'mixed'], 2)
    assert 'Unsupported native I/O ABI' in json.loads(wrong_init.stdout)['diagnostics'][0]['message']
    assert not (root / 'architecture.yaml').exists()
    (root / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    invoke(['export', '--format', 'mermaid', '--out', 'wrong.mmd'], 2)
    assert not (root / 'wrong.mmd').exists()
    detached = base / 'detached'
    detached.mkdir()
    shutil.copy2(binary, detached / executable_name)
    binary = detached / executable_name
    invoke(['validate'], 0)
    invoke(['export', '--format', 'mermaid', '--out', 'detached.mmd'], 2)
    assert not (root / 'detached.mmd').exists()
print(f'{count} relocated/missing/wrong-ABI {target} native asset cases passed')
