"""Private all-target pub stage identity, not archive or installation acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_delivery import staged_pubspec

from audit_installation_transports import audit
from combine_installations import MAX_FILE, PAYLOADS, ordinary, read_record, validate_record
from installation_artifact import _inventory, _sha256, source_identity
from pub_stage_inventory import validate_stage


def verify(stage, source, combined, transports, expected_commit, *, registry_ready=False):
    for root in [stage, source, combined, transports]:
        if root.absolute() != root.resolve() or not root.is_dir():
            raise ValueError('Missing or aliased acceptance root')
    identity = source_identity(source)
    if identity['commit'] != expected_commit:
        raise ValueError('Source differs from expected commit')
    previous = Path.cwd()
    try:
        os.chdir(source)
        directories = [transports / target for target in PAYLOADS]
        records = [read_record(directory / 'provenance.json') for directory in directories]
        for target, record in zip(PAYLOADS, records):
            validate_record(record)
            if record['target'] != target:
                raise ValueError('Transport target differs from directory')
        audited = audit(directories, expected_commit)
    finally:
        os.chdir(previous)
    if read_record(combined / 'transport-audit.json') != audited:
        raise ValueError('Combined audit differs from original transports')
    installation_files = {}
    for target, record in zip(PAYLOADS, records):
        if read_record(combined / 'provenance' / (target + '.json')) != record:
            raise ValueError('Combined provenance differs from original transport')
        for name, entry in record['files'].items():
            if name.startswith(('bin/', 'native/')) or target == 'linux-x64':
                installation_files[name] = entry
    actual = _inventory(combined / 'installation', installation_files)
    if actual != installation_files:
        raise ValueError('Combined installation differs from audited inputs')
    tracked = subprocess.run(['git', '-C', str(source), 'ls-files', '-z'],
                             capture_output=True, check=True).stdout.decode().split('\0')
    expected = {name: entry['sha256'] for name, entry in installation_files.items()
                if name.startswith(('native/', 'assets/'))}
    mappings = {'pubspec.yaml': 'pubspec.yaml', 'tool/npm/README.md': 'README.md',
                'LICENSE': 'LICENSE', 'CHANGELOG.md': 'CHANGELOG.md',
                'contracts/json/policy.schema.json': 'schemas/policy.schema.json',
                'contracts/json/public-result.schema.json': 'schemas/public-result.schema.json',
                'contracts/json/export-diagnostics.schema.json': 'schemas/export-diagnostics.schema.json'}
    for name in tracked:
        if name.startswith(('bin/', 'lib/')):
            mappings[name] = name
    for name, destination in mappings.items():
        if name.startswith('contracts/json/') and name not in tracked:
            raise ValueError(f'Untracked public schema: {name}')
        ordinary(source / name, MAX_FILE)
        expected[destination] = (hashlib.sha256(staged_pubspec(
            (source / name).read_bytes(), registry_ready=registry_ready)).hexdigest()
            if name == 'pubspec.yaml' else _sha256(source / name))
    checked = validate_stage(stage, expected, registry_ready=registry_ready)
    if registry_ready:
        checked['registry_ready'] = True
    return {'scope': 'all-target pub stage identity only' if registry_ready else 'private all-target pub stage identity only', 'source': identity,
            'transport_audit': audited, **checked}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['stage', 'source', 'combined', 'transports']:
        parser.add_argument('--' + name, required=True, type=lambda value: Path(value).absolute())
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--registry-ready', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(verify(**vars(args)), sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Pub stage verification failed: {error}\n')
