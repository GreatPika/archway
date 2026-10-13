"""Build an unsigned/unnotarized pkg from an already verified release bundle.

Python is a maintainer prerequisite only. --stage-only is a packaging fixture
boundary and does not establish native install or downloaded-file acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
IDENTIFIER = 'org.archway.cli'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(bundle, output):
    if bundle.resolve() != bundle or not bundle.is_dir():
        raise ValueError('Bundle must be an ordinary canonical directory')
    if output.exists() or output.is_symlink():
        raise ValueError('Output must be fresh and outside the input bundle')
    output = output.resolve()
    if bundle == output or bundle in output.parents:
        raise ValueError('Output must be fresh and outside the input bundle')
    manifest = json.loads((bundle / 'manifest.json').read_text())
    if manifest['target'] != 'macos-arm64' or manifest['schema_version'] != 1:
        raise ValueError('Expected macos-arm64 release bundle')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', manifest['version']):
        raise ValueError('Expected numeric package version')
    files = manifest['files']
    if not isinstance(files, dict):
        raise ValueError('Missing release inventory')
    required = {'bin/macos-arm64/archway', 'native/macos-arm64/libarchway_io.dylib',
                'LICENSE', 'README.txt', 'schemas/policy.schema.json',
                'schemas/public-result.schema.json', 'schemas/export-diagnostics.schema.json',
                'assets/typescript/licenses/pnpm-MIT.txt', 'assets/typescript/licenses/yaml-ISC.txt'}
    if not required <= files.keys():
        raise ValueError('Incomplete release bundle')
    actual = set()
    for path in bundle.rglob('*'):
        relative = path.relative_to(bundle).as_posix()
        if (not re.fullmatch(r'[A-Za-z0-9_./-]+', relative)
                or any(p in ('', '.', '..') for p in relative.split('/'))
                or path.is_symlink() or not (path.is_file() or path.is_dir())):
            raise ValueError('Unsafe bundle path')
        if path.is_dir():
            continue
        actual.add(relative)
        if relative == 'manifest.json':
            continue
        entry = files.get(relative)
        if (not entry or digest(path) != entry['sha256'] or path.stat().st_size != entry['size']
                or path.stat().st_mode & 0o7777 != entry['mode']):
            raise ValueError('Release inventory mismatch: ' + relative)
    if actual != set(files) | {'manifest.json'}:
        raise ValueError('Release inventory file set mismatch')
    if files['bin/macos-arm64/archway']['mode'] != 0o755:
        raise ValueError('Native executable must retain executable permissions')
    if any(entry['mode'] not in (0o644, 0o755) for entry in files.values()):
        raise ValueError('Unexpected payload permissions')
    if any(name.startswith('.') or name == 'uninstall.sh' for name in files):
        raise ValueError('Reserved installer metadata path')
    payload = output / 'root/usr/local/lib/archway'
    shutil.copytree(bundle, payload)
    scripts = output / 'scripts'
    scripts.mkdir()
    common = (HERE / 'lifecycle.sh').read_text()
    for name in ('preinstall', 'postinstall'):
        (scripts / name).write_text(common + '\n' + name + ' "$@"\n')
        (scripts / name).chmod(0o755)
    (payload / 'uninstall.sh').write_text(common + '\nuninstall "$@"\n')
    (payload / 'uninstall.sh').chmod(0o755)
    owned = sorted(p for p in payload.rglob('*') if p.is_file())
    (scripts / 'owned.sha256').write_text(''.join(
        f'{digest(p)} {p.stat().st_mode & 0o7777:o} {p.relative_to(payload).as_posix()}\n' for p in owned))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    if not args.stage_only and (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('pkgbuild requires a native macOS arm64 host; use --stage-only for fixtures')
    manifest = stage(args.bundle.absolute(), args.output.absolute())
    if not args.stage_only:
        package = args.output / f"archway-{manifest['version']}-macos-arm64-unsigned.pkg"
        subprocess.run(['/usr/bin/pkgbuild', '--root', str(args.output / 'root'),
                        '--scripts', str(args.output / 'scripts'), '--identifier', IDENTIFIER,
                        '--version', manifest['version'], '--install-location', '/',
                        '--ownership', 'recommended', str(package)], check=True)
        (args.output / 'installer-evidence.json').write_text(json.dumps({
            'source': manifest['source'], 'target': 'macos-arm64',
            'host': {'system': platform.system(), 'machine': platform.machine(),
                     'release': platform.release()},
            'route': 'unsigned-unnotarized-pkg-build', 'sha256': digest(package),
            'filename': package.name, 'bundle_manifest_sha256': digest(args.bundle / 'manifest.json'),
            'installer_inputs_sha256': {name: digest(HERE / name)
                                        for name in ('build.py', 'lifecycle.sh')},
            'scope': 'Build only; not lifecycle, fresh-terminal or downloaded-file GUI acceptance'
        }, indent=2) + '\n')
        print(f'{digest(package)}  {package.resolve()}')
    print('Staged unsigned/unnotarized installer; no publication or route certification.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f'macOS installer failed: {error}')
