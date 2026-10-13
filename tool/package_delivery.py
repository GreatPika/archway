"""Maintainer packaging extension to assemble.sh; never called at install/launch."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

TARGETS = {'linux-x64': ('archway', 'libarchway_io.so'),
           'macos-arm64': ('archway', 'libarchway_io.dylib'),
           'windows-x64': ('archway.exe', 'archway_io.dll')}

REPOSITORY = Path(__file__).resolve().parents[1]


def require_tree(directory):
    if not directory.is_dir() or directory.resolve() != directory:
        raise ValueError(f'Missing or aliased package tree: {directory}')
    for file in directory.rglob('*'):
        if file.is_symlink() or not (file.is_file() or file.is_dir()):
            raise ValueError(f'Nonordinary or aliased package asset: {file}')


def staged_pubspec(source, *, registry_ready=False):
    """Render only the publication destination; preserve source dependency pins."""
    if not registry_ready:
        return source
    lines = source.splitlines(keepends=True)
    fields = [line for line in lines if line.startswith(b'publish_to:')]
    if fields != [b'publish_to: none\n']:
        raise ValueError('Expected one private source publication destination')
    return source.replace(b'publish_to: none\n', b'publish_to: https://pub.dev\n', 1)


def stage(mode, output, installation, *, registry_ready=False):
    if output.exists() or output.is_symlink():
        raise ValueError(f'Assembly output already exists: {output}')
    if mode not in ['npm', 'npm-private-linux', 'pub', 'pub-private-linux']:
        raise ValueError(f'Unknown package mode: {mode}')
    if registry_ready and mode.endswith('-private-linux'):
        raise ValueError('Registry-ready staging requires all-target mode')
    is_npm = mode.startswith('npm')
    targets = ['linux-x64'] if mode.endswith('-private-linux') else list(TARGETS)
    for target in targets:
        executable, bridge = TARGETS[target]
        required = [f'native/{target}/{bridge}']
        if is_npm:
            required.append(f'bin/{target}/{executable}')
        for relative in required:
            asset = installation / relative
            if not asset.is_file() or asset.resolve() != asset:
                raise ValueError(f'Missing or aliased required target asset: {relative}')
    for directory in (['bin'] if is_npm else []) + ['native', 'assets']:
        require_tree(installation / directory)
    for notice in ['pnpm-MIT.txt', 'yaml-ISC.txt']:
        if not (installation / 'assets/typescript/licenses' / notice).is_file():
            raise ValueError(f'Missing required redistribution notice: {notice}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archway-package-', dir=output.parent) as temporary:
        prepared = Path(temporary) / 'package'
        prepared.mkdir()
        for directory in (['bin'] if is_npm else []) + ['native', 'assets']:
            shutil.copytree(installation / directory, prepared / directory)
        if is_npm:
            shutil.copy2(REPOSITORY / 'tool/npm/archway.cjs', prepared / 'bin/archway.cjs')
            (prepared / 'bin/archway.cjs').chmod(0o755)
            (prepared / 'package.json').write_text(json.dumps({
                'name': 'archway-architecture-cli', 'version': '0.1.0', 'private': not registry_ready,
                'description': ('PRIVATE Linux-only staging of the Archway architecture CLI.'
                                if mode.endswith('-private-linux') else
                                'Architecture policy CLI for TypeScript and Dart projects.'),
                'license': 'MIT',
                'bin': {'archway': 'bin/archway.cjs'},
            }, indent=2) + '\n')
        else:
            for directory in ['bin', 'lib']:
                require_tree(REPOSITORY / directory)
                shutil.copytree(REPOSITORY / directory, prepared / directory)
            (prepared / 'pubspec.yaml').write_bytes(staged_pubspec(
                (REPOSITORY / 'pubspec.yaml').read_bytes(), registry_ready=registry_ready))
        for name in ['LICENSE', 'CHANGELOG.md']:
            shutil.copy2(REPOSITORY / name, prepared / name)
        (prepared / 'schemas').mkdir()
        for name in ('policy.schema.json', 'public-result.schema.json',
                     'export-diagnostics.schema.json'):
            shutil.copy2(REPOSITORY / 'contracts/json' / name, prepared / 'schemas' / name)
        shutil.copy2(REPOSITORY / 'tool/npm/README.md', prepared / 'README.md')
        hashes = {file.relative_to(prepared).as_posix(): hashlib.sha256(file.read_bytes()).hexdigest()
                  for file in sorted(prepared.rglob('*')) if file.is_file()}
        (prepared / 'manifest.json').write_text(json.dumps({
            'private': not registry_ready, 'partial': mode.endswith('-private-linux'), 'targets': targets,
            'versions': {'archway': '0.1.0', 'dart': '3.13.3', 'node': '24.21.0',
                         'typescript': '5.9.3', 'yaml': '2.8.1'}, 'sha256': hashes,
        }, indent=2) + '\n')
        prepared.rename(output)
    print(f'Package staged ({mode}; no registry publication): {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['npm', 'npm-private-linux', 'pub', 'pub-private-linux'])
    parser.add_argument('output', type=lambda value: Path(value).absolute())
    parser.add_argument('installation', type=lambda value: Path(value).resolve())
    parser.add_argument('--registry-ready', action='store_true',
                        help='Stage final registry metadata; never publish or certify a package')
    args = parser.parse_args()
    try:
        stage(**vars(args))
    except (OSError, ValueError, IndexError) as error:
        sys.exit(f'Package assembly failed: {error}')
