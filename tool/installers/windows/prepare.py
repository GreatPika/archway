"""Convert an already verified Windows release bundle to Inno build inputs.

This is not assembly or certification. The release owner verifies source/transport
provenance before calling this converter. Input bytes are never modified.
"""
import argparse
import re
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from release_bundles import inventory
from ci.combine_installations import read_record


def prepare(payload, output):
    payload = payload.absolute()
    output = output.absolute()
    prospective = output.resolve()
    if prospective != output or prospective.is_relative_to(payload.resolve()):
        raise ValueError('Inno build directory must be canonical and outside the payload')
    if output.exists() or output.is_symlink():
        raise ValueError('Inno build directory must be fresh')
    files = inventory(payload)
    manifest = read_record(payload / 'manifest.json')
    expected = {name: entry for name, entry in files.items() if name != 'manifest.json'}
    # POSIX mode is provenance metadata, not a Windows filesystem capability.
    recorded = manifest.get('files', {})
    if (manifest.get('target') != 'windows-x64' or recorded.keys() != expected.keys()
            or any(recorded[n].get(k) != e[k] for n, e in expected.items()
                   for k in ('sha256', 'size'))):
        raise ValueError('Windows release manifest does not match payload bytes')
    if 'bin/windows-x64/archway.exe' not in files:
        raise ValueError('Windows native command missing')
    seen = set()
    names = {}
    rows = []
    entries = []
    for name, record in files.items():
        parts = name.split('/')
        if (any(not p or p.endswith((' ', '.')) or
                re.search(r'[<>:"\\|?*\x00-\x1f{}]', p) or
                re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', p)
                for p in parts)
                or name.casefold() in seen or
                parts[0].casefold().startswith(('unins', '.archway-'))):
            raise ValueError('Unsafe or colliding Windows installer member')
        for length in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:length])
            prior = names.setdefault(prefix.casefold(), prefix)
            if prior != prefix:
                raise ValueError('Case-aliased Windows installer directory')
        seen.add(name.casefold())
        windows_name = name.replace('/', '\\')
        rows.append(record['sha256'] + '\t' + windows_name)
        source = str(payload / name).replace('"', '""').replace('{', '{{')
        destination = '{app}' + ('\\' + '\\'.join(parts[:-1]) if len(parts) > 1 else '')
        entries.append(f'Source: "{source}"; DestDir: "{destination}"; Flags: ignoreversion')
    output.mkdir(parents=True)
    (output / 'owned-files.txt').write_text('\n'.join(rows) + '\n', encoding='utf-8')
    (output / 'payload.iss').write_text('\n'.join(entries) + '\n', encoding='utf-8')
    for name in ('archway.iss', 'lifecycle.iss'):
        shutil.copyfile(Path(__file__).with_name(name), output / name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        prepare(args.payload, args.output)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'{error}\n')
