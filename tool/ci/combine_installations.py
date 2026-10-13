"""CI-only verified transport combination; no installation certification."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import hashlib
import gzip
import re
import stat
import tarfile
import shutil
import tempfile

from audit_installation_transports import audit
from installation_artifact import _sha256

# Deliberately finite CI bounds, comfortably above current 45 MB transports.
MAX_FILE = 128 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
MAX_FILES = 4096
MAX_JSON = 2 * 1024 * 1024
PAYLOADS = {
    'linux-x64': ('archway', 'libarchway_io.so'),
    'macos-arm64': ('archway', 'libarchway_io.dylib'),
    'windows-x64': ('archway.exe', 'archway_io.dll')}

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key')
        result[key] = value
    return result

def ordinary(path, limit):
    if path.resolve() != path.absolute() or not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError('Aliased or nonregular transport input')
    if path.stat().st_size > limit:
        raise ValueError('Transport input exceeds bound')

def read_record(path):
    ordinary(path, MAX_JSON)
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_object)

def canonical(name):
    path = PurePosixPath(name)
    return (bool(name) and path.as_posix() == name and not path.is_absolute()
            and name != '.' and '..' not in path.parts and '\\' not in name
            and ':' not in name and not any(ord(c) < 32 for c in name))

def validate_record(record):
    if not isinstance(record, dict) or set(record) != {
            'schema_version', 'source', 'target', 'host', 'checks',
            'runtimes', 'files', 'archive'}:
        raise ValueError('Invalid provenance shape')
    target = record['target']
    if not isinstance(target, str) or target not in PAYLOADS:
        raise ValueError('Invalid target')
    for key in ['source', 'host', 'checks', 'runtimes', 'archive', 'files']:
        if not isinstance(record[key], dict):
            raise ValueError('Invalid provenance object')
    if set(record['host']) != {'system', 'machine', 'release'}:
        raise ValueError('Invalid host shape')
    runtimes = record['runtimes']
    expected_runtimes = {'build_dart'} if target == 'windows-x64' else {
        'build_dart', 'analysis_dart', 'analysis_node'}
    if (set(runtimes) != expected_runtimes
            or any(not isinstance(v, str) or not v or len(v) > 512 for v in runtimes.values())):
        raise ValueError('Invalid runtime evidence')
    executable, bridge = PAYLOADS[target]
    required = {f'bin/{target}/{executable}', f'native/{target}/{bridge}'}
    files = record['files']
    if not required <= files.keys() or not 3 <= len(files) <= MAX_FILES:
        raise ValueError('Missing payload or invalid file count')
    shared_required = {'assets/typescript/' + name for name in [
        'licenses/pnpm-MIT.txt', 'licenses/yaml-ISC.txt',
        'vendor/typescript/package.json', 'vendor/typescript/lib/typescript.js',
        'vendor/yaml/package.json', 'vendor/yaml/dist/index.js']}
    source_assets = Path.cwd() / 'assets/typescript'
    tracked_assets = set()
    for pattern in ['*.cjs', '*.json', '*.md', 'licenses/*.txt']:
        for file in source_assets.glob(pattern):
            name = file.relative_to(Path.cwd()).as_posix()
            shared_required.add(name)
            tracked_assets.add(name)
            if name not in files or files[name].get('sha256') != _sha256(file):
                raise ValueError('Shared tracked asset differs from source')
    if not shared_required <= files.keys():
        raise ValueError('Missing required shared asset')
    total = 0
    for name, entry in files.items():
        if not canonical(name):
            raise ValueError('Noncanonical file key')
        parts = PurePosixPath(name).parts
        asset = (len(parts) >= 3 and parts[:2] == ('assets', 'typescript')
                 and ((len(parts) == 3 and name in tracked_assets)
                      or (len(parts) == 4 and parts[2] == 'licenses'
                          and parts[3] in {'pnpm-MIT.txt', 'yaml-ISC.txt'})
                      or (len(parts) >= 5 and parts[2] == 'vendor'
                          and parts[3] in {'typescript', 'yaml'})))
        if name not in required and not asset:
            raise ValueError('File outside fixed target layout')
        modes = {0o666, 0o777} if target == 'windows-x64' else {0o644, 0o755}
        if (not isinstance(entry, dict) or set(entry) != {'size', 'mode', 'sha256'}
                or type(entry['size']) is not int or not 0 <= entry['size'] <= MAX_FILE
                or type(entry['mode']) is not int or entry['mode'] not in modes
                or not isinstance(entry['sha256'], str)
                or not re.fullmatch('[0-9a-f]{64}', entry['sha256'])):
            raise ValueError('Invalid or unbounded inventory entry')
        if name.startswith('bin/') and target != 'windows-x64' and entry['mode'] != 0o755:
            raise ValueError('Unix payload lacks execute mode')
        total += entry['size']
    if total > MAX_TOTAL:
        raise ValueError('Expanded installation exceeds bound')

def check_members(archive, files, root=None):
    seen = set()
    with tarfile.open(archive, 'r:') as stream:
        for member in stream:
            entry = files.get(member.name)
            if (entry is None or member.name in seen or not member.isreg()
                    or member.sparse is not None or member.linkname
                    or member.size != entry['size'] or member.mode != entry['mode']):
                raise ValueError(f'Unexpected archive member: {member.name}')
            seen.add(member.name)
            if root is not None:
                path = root / member.name
                path.parent.mkdir(parents=True, exist_ok=True)
                digest = hashlib.sha256(); size = 0
                with stream.extractfile(member) as source, path.open('xb') as output:
                    while block := source.read(1024 * 1024):
                        size += len(block); digest.update(block); output.write(block)
                if size != entry['size'] or digest.hexdigest() != entry['sha256']:
                    raise ValueError('Extracted bytes differ from manifest')
                path.chmod(entry['mode'])
    if seen != files.keys():
        raise ValueError('Missing archive members')


def combine(directories, expected_commit, output):
    if os.path.lexists(output):
        raise ValueError('Output already exists')
    if len(directories) != 3:
        raise ValueError('Exactly three transport directories are required')
    records = []
    for directory in directories:
        record = read_record(directory / 'provenance.json')
        validate_record(record)
        ordinary(directory / 'installation.tar', MAX_TOTAL)
        records.append(record)
    report = audit(directories, expected_commit)
    # All metadata in all three archives is checked before any extraction.
    for directory, record in zip(directories, records):
        check_members(directory / 'installation.tar', record['files'])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archway-combine-', dir=output.parent) as temporary:
        stage = Path(temporary)
        result = stage / 'result'
        installation = result / 'installation'
        provenance = result / 'provenance'
        installation.mkdir(parents=True); provenance.mkdir()
        for directory, record in zip(directories, records):
            target = record['target']
            root = stage / target
            check_members(directory / 'installation.tar', record['files'], root)
            for kind in ['bin', 'native']:
                shutil.copytree(root / kind / target, installation / kind / target)
            if target == 'linux-x64':
                shutil.copytree(root / 'assets', installation / 'assets')
            shutil.copy2(directory / 'provenance.json', provenance / f'{target}.json')
        (result / 'transport-audit.json').write_text(json.dumps(report, indent=2) + '\n')
        result.rename(output)


def verify_pack(package, packed, *, registry_ready=False):
    manifest = read_record(package / 'manifest.json')
    metadata = read_record(package / 'package.json')
    if (manifest.get('private') is not (not registry_ready) or manifest.get('partial') is not False
            or set(manifest.get('targets', [])) != set(PAYLOADS)
            or metadata.get('private') is not (not registry_ready) or metadata.get('scripts')):
        raise ValueError('Package differs from expected all-target script-free staging mode')
    hashes = manifest['sha256']
    if not isinstance(hashes, dict) or not 1 <= len(hashes) <= MAX_FILES:
        raise ValueError('Invalid package manifest')
    required = {name for target, (executable, bridge) in PAYLOADS.items()
                for name in [f'bin/{target}/{executable}', f'native/{target}/{bridge}']}
    if not required <= hashes.keys() or 'manifest.json' in hashes:
        raise ValueError('Missing required packed native targets or circular manifest')
    if registry_ready:
        required_notices = {'LICENSE', 'README.md', 'CHANGELOG.md',
            'assets/typescript/vendor/typescript/LICENSE.txt',
            'assets/typescript/vendor/yaml/LICENSE',
            'assets/typescript/licenses/pnpm-MIT.txt', 'assets/typescript/licenses/yaml-ISC.txt'}
        if not required_notices <= hashes.keys():
            raise ValueError('Missing registry documentation or redistribution notice')
    expected = {}
    for name, digest in {**hashes, 'manifest.json': _sha256(package / 'manifest.json')}.items():
        if not canonical(name) or not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Invalid package file inventory')
        file = package / name
        ordinary(file, MAX_FILE)
        if _sha256(file) != digest:
            raise ValueError('Staged package differs from manifest')
        expected[name] = {'size': file.stat().st_size, 'sha256': digest}
    actual = {p.relative_to(package).as_posix() for p in package.rglob('*') if p.is_file()}
    if actual != expected.keys():
        raise ValueError('Staged package file set differs from manifest')
    summary = read_record(packed / 'npm-pack.json')
    if not isinstance(summary, list) or len(summary) != 1 or not isinstance(summary[0], dict):
        raise ValueError('Expected one npm pack result')
    summary = summary[0]
    filename = summary['filename']
    if not isinstance(filename, str) or not canonical(filename) or '/' in filename or not filename.endswith('.tgz'):
        raise ValueError('Invalid npm tarball filename')
    archive = packed / filename
    ordinary(archive, MAX_TOTAL)
    seen = set(); unpacked = 0
    # tarfile stops at its end marker without necessarily reading gzip's trailer.
    # Validate the entire compressed stream before parsing any tar metadata.
    # Include headers/PAX bodies/padding in the bound, not just yielded file sizes.
    expanded_limit = min(MAX_TOTAL, sum(e['size'] for e in expected.values()) + 16 * 1024 * 1024)
    with tempfile.TemporaryFile() as decoded:
        expanded = 0
        with gzip.open(archive, 'rb') as compressed:
            while block := compressed.read(1024 * 1024):
                expanded += len(block)
                if expanded > expanded_limit:
                    raise ValueError('Full gzip expansion exceeds bound')
                decoded.write(block)
        decoded.seek(0)
        with tarfile.open(fileobj=decoded, mode='r|') as stream:
            for member in stream:
                name = member.name.removeprefix('package/')
                entry = expected.get(name)
                if (not member.name.startswith('package/') or entry is None or name in seen
                        or not member.isreg() or member.sparse is not None or member.linkname
                        or member.size != entry['size'] or member.mode not in {0o644, 0o755}):
                    raise ValueError('Unexpected packed member')
                if name.startswith(('bin/linux-x64/', 'bin/macos-arm64/')) and member.mode != 0o755:
                    raise ValueError('Packed Unix executable lost execute mode')
                seen.add(name); unpacked += member.size
                if unpacked > MAX_TOTAL:
                    raise ValueError('Packed expansion exceeds bound')
                with stream.extractfile(member) as source:
                    digest = hashlib.file_digest(source, 'sha256').hexdigest()
                if digest != entry['sha256']:
                    raise ValueError('Packed bytes differ from package manifest')
    listing = summary['files']
    if (seen != expected.keys() or not isinstance(listing, list)
            or len(listing) != len(expected)
            or {item['path']: item['size'] for item in listing} != {n: e['size'] for n, e in expected.items()}
            or summary['size'] != archive.stat().st_size or summary['unpackedSize'] != unpacked):
        raise ValueError('npm listing or archive totals differ from actual packed files')
    evidence = {'scope': 'packed-file acceptance only; no installed-route certification',
                'filename': filename, 'sha256': _sha256(archive),
                'compressed_bytes': archive.stat().st_size, 'unpacked_bytes': unpacked,
                'files': len(seen), 'manifest_sha256': expected['manifest.json']['sha256'],
                'targets': manifest['targets']}
    if registry_ready:
        evidence['registry_ready'] = True
    destination = packed / 'packed-evidence.json'
    with destination.open('x', encoding='utf-8') as output:
        output.write(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
    print(json.dumps(evidence, sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    combiner = commands.add_parser('combine')
    combiner.add_argument('--expected-commit', required=True)
    combiner.add_argument('--output', required=True, type=Path)
    combiner.add_argument('directories', nargs='+', type=Path)
    verifier = commands.add_parser('verify-pack')
    verifier.add_argument('--package', required=True, type=Path)
    verifier.add_argument('--packed-directory', required=True, type=Path)
    verifier.add_argument('--registry-ready', action='store_true')
    args = parser.parse_args()
    if args.operation == 'combine':
        combine(args.directories, args.expected_commit, args.output.absolute())
    else:
        verify_pack(args.package.absolute(), args.packed_directory.absolute(),
                    registry_ready=args.registry_ready)
