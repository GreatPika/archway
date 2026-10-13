"""Build an unsigned .deb from an extracted, verified native release bundle."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ci'))
from combine_installations import MAX_FILE, MAX_TOTAL, canonical, ordinary, read_record
from installation_artifact import _inventory, _sha256


def build(args):
    bundle = args.bundle.absolute()
    output = args.output.absolute()
    if bundle.resolve() != bundle or not bundle.is_dir():
        raise ValueError('Bundle must be an ordinary canonical directory')
    if os.path.lexists(output):
        raise ValueError('Output must be fresh and outside the input bundle')
    output = output.resolve()
    if bundle in output.parents:
        raise ValueError('Output must be fresh and outside the input bundle')
    manifest = read_record(bundle / 'manifest.json')
    if (manifest.get('schema_version') != 1 or manifest.get('target') != 'linux-x64'
            or manifest.get('source', {}).get('commit') != args.expected_commit
            or not re.fullmatch('[0-9a-f]{40}', args.expected_commit)
            or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', manifest.get('version', ''))):
        raise ValueError('Wrong release target, source or version')
    files = manifest['files']
    required = {'bin/linux-x64/archway', 'native/linux-x64/libarchway_io.so',
                'LICENSE', 'README.txt', 'schemas/policy.schema.json',
                'schemas/public-result.schema.json', 'schemas/export-diagnostics.schema.json'}
    assets = Path(__file__).resolve().parents[3] / 'assets/typescript'
    for pattern in ('*.cjs', '*.json', '*.md', 'licenses/*.txt'):
        required.update('assets/typescript/' + path.relative_to(assets).as_posix()
                        for path in assets.glob(pattern))
    required.update('assets/typescript/vendor/' + name for name in (
        'typescript/package.json', 'typescript/lib/typescript.js',
        'typescript/LICENSE.txt', 'yaml/package.json', 'yaml/dist/index.js', 'yaml/LICENSE'))
    if not isinstance(files, dict) or not required <= files.keys():
        raise ValueError('Incomplete release bundle')
    total = 0
    for name, entry in files.items():
        if (not canonical(name) or name == 'manifest.json'
                or not isinstance(entry, dict) or set(entry) != {'mode', 'size', 'sha256'}
                or entry['mode'] not in (0o644, 0o755)
                or type(entry['size']) is not int or not 0 <= entry['size'] <= MAX_FILE):
            raise ValueError('Invalid release inventory')
        total += entry['size']
    if total > MAX_TOTAL or files['bin/linux-x64/archway']['mode'] != 0o755:
        raise ValueError('Invalid release size or executable mode')
    ordinary(bundle / 'manifest.json', MAX_FILE)
    expected = {**files, 'manifest.json': {
        'size': (bundle / 'manifest.json').stat().st_size,
        'mode': 0o644, 'sha256': _sha256(bundle / 'manifest.json')}}
    if _inventory(bundle, expected) != expected:
        raise ValueError('Release bundle differs from inventory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archway-deb-', dir=output.parent) as temp:
        stage = Path(temp) / 'package'
        payload = stage / 'usr/lib/archway'
        shutil.copytree(bundle, payload)
        if _inventory(payload, expected) != expected:
            raise ValueError('Staged payload differs from release inventory')
        (stage / 'usr/bin').mkdir(parents=True)
        (stage / 'usr/bin/archway').symlink_to('/usr/lib/archway/bin/linux-x64/archway')
        control = stage / 'DEBIAN'
        control.mkdir()
        (control / 'control').write_text(
            'Package: archway\nVersion: ' + manifest['version'] + '\n'
            'Architecture: amd64\nMaintainer: Archway maintainers\n'
            'Section: devel\nPriority: optional\n'
            'Description: Architecture checks for prepared TypeScript and Dart projects\n'
            ' Unsigned preview. Analysis runtimes are separate prerequisites.\n', encoding='utf-8')
        preinst = (Path(__file__).with_name('preinst')).read_text(encoding='utf-8')
        preinst += '\nwhile IFS= read -r path; do\n'
        preinst += '    if exists "$root$path"; then\n'
        preinst += '        [ ! -L "$root$path" ] && [ -f "$root$path" ] || conflict "$path is not an ordinary file"\n'
        preinst += '        owned "$path" || conflict "$path is not owned by this package"\n'
        preinst += '    fi\n'
        preinst += '    parent=${path%/*}\n'
        preinst += '    while [ "$parent" != /usr/lib ]; do\n'
        preinst += '        if exists "$root$parent"; then\n'
        preinst += '            [ ! -L "$root$parent" ] && [ -d "$root$parent" ] || conflict "$parent is not an ordinary directory"\n'
        preinst += '        fi\n'
        preinst += '        parent=${parent%/*}\n'
        preinst += '    done\n'
        preinst += "done <<'ARCHWAY_FILES'\n"
        preinst += ''.join('/usr/lib/archway/' + name + '\n' for name in sorted(expected))
        preinst += 'ARCHWAY_FILES\n'
        (control / 'preinst').write_text(preinst, encoding='utf-8')
        (control / 'preinst').chmod(0o755)
        artifact = Path(temp) / 'archway.deb'
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(stage),
                        str(artifact)], check=True)
        readback = Path(temp) / 'readback'
        subprocess.run(['dpkg-deb', '--extract', str(artifact), str(readback)], check=True)
        if (_inventory(readback / 'usr/lib/archway', expected) != expected
                or os.readlink(readback / 'usr/bin/archway') !=
                '/usr/lib/archway/bin/linux-x64/archway'):
            raise ValueError('Packaged payload or command differs from stage')
        os.link(artifact, output)
    print(f'{_sha256(output)}  {output.name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    try:
        build(parser.parse_args())
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Archway package build failed: {error}\n')
