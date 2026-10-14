"""Audit same-run exporter manifests and opaque tar hashes; never extract or execute."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

from installation_artifact import source_identity, _sha256

TARGETS = {'linux-x64': ('Linux', 'x86_64'), 'macos-arm64': ('Darwin', 'arm64'),
           'windows-x64': ('Windows', 'AMD64')}


def audit(directories, expected_commit):
    source = source_identity(Path.cwd())
    if source['commit'] != expected_commit:
        raise ValueError('Checkout differs from expected workflow commit')
    targets = {}
    shared = None
    for directory in directories:
        record = json.loads((directory / 'provenance.json').read_text(encoding='utf-8'))
        if record['source'] != source:
            raise ValueError('Manifest source differs from checked-out commit/tree/locks')
        target = record['target']
        if target not in TARGETS or target in targets:
            raise ValueError('Unknown or duplicate target')
        if type(record['schema_version']) is not int or record['schema_version'] != 1:
            raise ValueError('Unsupported manifest schema')
        host, checks = record['host'], record['checks']
        suites = [] if target == 'windows-x64' else [
            'native_asset_process_smoke.dart', 'cli_process_smoke.dart',
            'dart_check_process_smoke.dart', 'alias_trace_gap_process_smoke.dart']
        profile = 'init-only' if target == 'windows-x64' else 'process'
        if ((host['system'], host['machine']) != TARGETS[target]
                or not isinstance(host['release'], str) or not host['release']
                or checks != dict(profile=profile, suites=suites,
                                  relocated_init=True, transported_init=True)
                or checks['relocated_init'] is not True
                or checks['transported_init'] is not True):
            raise ValueError(f'Host or required check profile mismatch: {target}')
        for name, entry in record['files'].items():
            path = PurePosixPath(name)
            if (not name or path.is_absolute() or path.as_posix() != name
                    or '..' in path.parts or '\\' in name or ':' in name
                    or set(entry) != {'size', 'sha256', 'mode'}
                    or type(entry['size']) is not int or entry['size'] < 0
                    or type(entry['mode']) is not int or not 0 <= entry['mode'] <= 0o7777
                    or not isinstance(entry['sha256'], str)
                    or not re.fullmatch('[0-9a-f]{64}', entry['sha256'])):
                raise ValueError(f'Invalid file inventory: {target}: {name}')
        assets = {name: {'size': entry['size'], 'sha256': entry['sha256']}
                  for name, entry in record['files'].items() if name.startswith('assets/')}
        if not assets:
            raise ValueError(f'Missing shared assets: {target}')
        if shared is not None and assets != shared:
            changed = sorted(name for name in assets.keys() | shared.keys()
                             if assets.get(name) != shared.get(name))
            raise ValueError(f'Shared assets differ for {target}: {changed}')
        shared = assets
        digest = _sha256(directory / 'installation.tar')
        if record['archive'] != {'name': 'installation.tar', 'sha256': digest}:
            raise ValueError(f'Archive identity mismatch: {target}')
        targets[target] = {'archive_sha256': digest,
                           'host': record['host'], 'checks': record['checks']}
    if set(targets) != set(TARGETS):
        raise ValueError('Missing required target')
    return {'scope': 'transport-only; no extraction or package certification',
            'shared_asset_sha256': hashlib.sha256(json.dumps(shared, sort_keys=True).encode()).hexdigest(),
            'source': source, 'targets': targets}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('directories', nargs='+', type=Path)
    args = parser.parse_args()
    report = audit(args.directories, args.expected_commit)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(json.dumps(report, sort_keys=True))
