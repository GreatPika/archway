"""Wrap verified same-source CI transports; never publish or claim release certification.

Run against a clean exact-commit source checkout. Original CI archives and records
are retained unchanged. Added release files are separately inventoried. The caller
must verify workflow status, license approval and native-host execution separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'ci'))
from combine_installations import (MAX_FILE, MAX_TOTAL, PAYLOADS, check_members,
                                   combine, ordinary, read_record, verify_pack)
from installation_artifact import _sha256, source_identity

VERSION = '0.1.0'


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_dir() and not path.is_symlink():
            continue
        ordinary(path, MAX_FILE)
        result[path.relative_to(root).as_posix()] = {
            'sha256': _sha256(path), 'size': path.stat().st_size,
            'mode': stat.S_IMODE(path.stat().st_mode)}
    return result


def zip_tree(root, destination):
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(root.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(root).as_posix())


def verify_bundle(archive, expected, windows):
    seen = set()
    if windows:
        with zipfile.ZipFile(archive) as stream:
            for item in stream.infolist():
                entry = expected.get(item.filename)
                if (entry is None or item.filename in seen or item.is_dir()
                        or item.file_size != entry['size']
                        or (item.external_attr >> 16) & 0o7777 != entry['mode']):
                    raise ValueError('Release ZIP inventory mismatch')
                with stream.open(item) as source:
                    if hashlib.file_digest(source, 'sha256').hexdigest() != entry['sha256']:
                        raise ValueError('Release ZIP bytes changed')
                seen.add(item.filename)
    else:
        with tarfile.open(archive, 'r:gz') as stream:
            for item in stream:
                entry = expected.get(item.name)
                if (entry is None or item.name in seen or not item.isreg()
                        or item.mode != entry['mode'] or item.size != entry['size']):
                    raise ValueError('Release tar inventory mismatch')
                with stream.extractfile(item) as source:
                    if hashlib.file_digest(source, 'sha256').hexdigest() != entry['sha256']:
                        raise ValueError('Release tar bytes changed')
                seen.add(item.name)
    if seen != expected.keys():
        raise ValueError('Release archive omitted files')


def build(args):
    # Resolve arguments before changing cwd; reject input leaf aliases rather than
    # silently converting them to their targets. Existing outputs are never replaced.
    source = args.source.absolute()
    transports = args.transports.absolute()
    packed = args.packed.absolute()
    guide = args.guide.absolute()
    output = args.output.absolute()
    ci_evidence = args.ci_evidence.absolute() if args.ci_evidence else None
    if os.path.lexists(output):
        raise ValueError('Release output already exists')
    ordinary(guide, 128 * 1024)
    guide.read_text(encoding='utf-8')
    os.chdir(source)
    identity = source_identity(source)
    if identity['commit'] != args.expected_commit:
        raise ValueError('Source checkout differs from expected commit')
    directories = [transports / target for target in PAYLOADS]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archway-release-', dir=output.parent) as temp:
        work = Path(temp)
        combined = work / 'combined'
        combine(directories, args.expected_commit, combined)
        # Reconstruct the expected npm stage with the exact source's own packager.
        # verify_pack checks every compressed byte and inventory against that stage.
        package = work / 'npm-stage'
        subprocess.run([sys.executable, str(source / 'tool/package_delivery.py'),
                        'npm', str(package), str(combined / 'installation'),
                        *(['--registry-ready'] if args.registry_ready else [])], check=True)
        verified_pack = work / 'verified-pack'
        verified_pack.mkdir()
        for name in ('npm-pack.json', 'archway-architecture-cli-0.1.0.tgz'):
            ordinary(packed / name, MAX_TOTAL)
            shutil.copy2(packed / name, verified_pack / name)
        verify_pack(package, verified_pack, registry_ready=args.registry_ready)
        original_pack = read_record(packed / 'packed-evidence.json')
        verified = read_record(verified_pack / 'packed-evidence.json')
        if original_pack != verified:
            raise ValueError('Original npm pack evidence differs from re-verification')
        result = work / 'release'
        result.mkdir()
        evidence = work / 'evidence'
        evidence.mkdir()
        if ci_evidence is not None:
            ci_inventory = inventory(ci_evidence)
            if sum(e['size'] for e in ci_inventory.values()) > MAX_TOTAL:
                raise ValueError('CI evidence exceeds bound')
            shutil.copytree(ci_evidence, evidence / 'ci')
            if inventory(evidence / 'ci') != ci_inventory:
                raise ValueError('CI evidence changed during copy')
        shutil.copy2(combined / 'transport-audit.json', evidence / 'transport-audit.json')
        shutil.copytree(combined / 'provenance', evidence / 'combined-provenance')
        pack_proof = evidence / 'npm'
        pack_proof.mkdir()
        for path in sorted(packed.iterdir()):
            if path.suffix == '.json' or path.name.endswith('-version.txt'):
                ordinary(path, 2 * 1024 * 1024)
                shutil.copy2(path, pack_proof / path.name)
        records = {}
        for directory in directories:
            record = read_record(directory / 'provenance.json')
            target = record['target']
            bundle = work / ('bundle-' + target)
            check_members(directory / 'installation.tar', record['files'], bundle)
            shutil.copy2(guide, bundle / 'README.txt')
            (bundle / 'README.txt').chmod(0o644)
            tracked = subprocess.run(['git', 'ls-files', '-z', '--', 'contracts/json'],
                                     check=True, capture_output=True).stdout.decode().split('\0')
            (bundle / 'schemas').mkdir()
            for name in ('policy.schema.json', 'public-result.schema.json',
                         'export-diagnostics.schema.json'):
                if 'contracts/json/' + name not in tracked:
                    raise ValueError(f'Untracked public schema: {name}')
                path = source / 'contracts/json' / name
                ordinary(path, MAX_FILE)
                destination = bundle / 'schemas' / name
                shutil.copy2(path, destination)
                destination.chmod(0o644)
            if (source / 'LICENSE').exists():
                ordinary(source / 'LICENSE', MAX_FILE)
                shutil.copy2(source / 'LICENSE', bundle / 'LICENSE')
                (bundle / 'LICENSE').chmod(0o644)
            files = inventory(bundle)
            for name, entry in record['files'].items():
                if files[name] != entry:
                    raise ValueError('Original payload changed during wrapping')
            write_json(bundle / 'manifest.json', {
                'schema_version': 1, 'version': VERSION, 'target': target,
                'versions': read_record(package / 'manifest.json')['versions'],
                'source': identity, 'original_archive': record['archive'],
                'files': files,
                'scope': 'Release packaging integrity; not a signature or platform certification'})
            (bundle / 'manifest.json').chmod(0o644)
            windows = target == 'windows-x64'
            name = f'archway-{VERSION}-{target}' + ('.zip' if windows else '.tar.gz')
            archive = result / name
            if windows:
                zip_tree(bundle, archive)
            else:
                with tarfile.open(archive, 'x:gz', format=tarfile.PAX_FORMAT) as stream:
                    for path in sorted(bundle.rglob('*')):
                        if path.is_file():
                            stream.add(path, path.relative_to(bundle).as_posix(), recursive=False)
            verify_bundle(archive, inventory(bundle), windows)
            original = evidence / 'original' / target
            original.mkdir(parents=True)
            for original_name in ('installation.tar', 'provenance.json'):
                shutil.copy2(directory / original_name, original / original_name)
                if _sha256(original / original_name) != _sha256(directory / original_name):
                    raise ValueError('Original evidence copy changed')
            records[target] = {'filename': name, 'sha256': _sha256(archive),
                               'original_archive': record['archive'],
                               'added_files': {n: e for n, e in inventory(bundle).items()
                                               if n not in record['files']}}
        shutil.copy2(verified_pack / verified['filename'], result / verified['filename'])
        shutil.copy2(guide, result / 'QUICKSTART.txt')
        write_json(evidence / 'release-packaging.json', {
            'schema_version': 1, 'version': VERSION, 'source': identity,
            'scope': 'Archive integrity only; workflow and native-host release gates remain separate',
            'native_bundles': records, 'npm_tarball': verified,
            'quickstart_sha256': _sha256(guide),
            'packager_sha256': _sha256(Path(__file__).resolve())})
        zip_tree(evidence, result / f'archway-{VERSION}-evidence.zip')
        (result / 'SHA256SUMS').write_text(''.join(
            f'{_sha256(path)}  {path.name}\n' for path in sorted(result.iterdir())), encoding='utf-8')
        if source_identity(source) != identity:
            raise ValueError('Source identity changed during wrapping')
        if os.path.lexists(output):
            raise ValueError('Release output appeared during wrapping')
        result.rename(output)
    print(f'Prepared {output}; no publication or platform certification performed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'transports', 'packed', 'guide', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--registry-ready', action='store_true')
    parser.add_argument('--ci-evidence', type=Path,
                        help='Optional reviewed directory of original workflow/route evidence')
    try:
        build(parser.parse_args())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(f'Release packaging refused: {error}')
