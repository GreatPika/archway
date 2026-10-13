"""Private CI bytes transport, not a pub-generated or hosted package archive."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

from combine_installations import (MAX_FILE, MAX_FILES, MAX_JSON, MAX_TOTAL,
    canonical, ordinary, unique_object)
from installation_artifact import _sha256, source_identity
from pub_stage_inventory import (validate_evidence, inspect_upload_archive, UPLOAD_ARCHIVE,
    PUB_COMPRESSED_LIMIT, PUB_EXPANDED_LIMIT)

ARCHIVE = 'pub-stage.tar.gz'
PREFIX = 'pub source café/'
METADATA = {'stage-identity.json', 'report.json'}


def expectation(text, source, run_id, run_attempt, *, registry_ready=False):
    if len(text.encode()) > 4096:
        raise ValueError('Expected transport record exceeds bound')
    value = json.loads(text, object_pairs_hook=unique_object)
    keys = {'schema_version', 'source', 'file_set_sha256', 'archive', 'run_id', 'run_attempt'}
    if registry_ready:
        keys |= {'registry_ready', 'upload_archive'}
    if (not isinstance(value, dict) or set(value) != keys
            or type(value['schema_version']) is not int
            or value['schema_version'] != (2 if registry_ready else 1)):
        raise ValueError('Invalid expected transport record')
    if registry_ready:
        upload = value['upload_archive']
        if (value['registry_ready'] is not True or not isinstance(upload, dict)
                or set(upload) != {'sha256', 'size', 'unpacked_bytes', 'files'}
                or not isinstance(upload['sha256'], str)
                or not re.fullmatch('[0-9a-f]{64}', upload['sha256'])
                or type(upload['size']) is not int or not 1 <= upload['size'] < PUB_COMPRESSED_LIMIT
                or type(upload['unpacked_bytes']) is not int or not 0 <= upload['unpacked_bytes'] < PUB_EXPANDED_LIMIT
                or type(upload['files']) is not int or not 1 <= upload['files'] < MAX_FILES):
            raise ValueError('Invalid expected pub upload archive')
    identity, archive = value['source'], value['archive']
    if (not isinstance(identity, dict) or set(identity) != {'commit', 'tree', 'lockfile_sha256'}
            or not isinstance(identity['lockfile_sha256'], dict)
            or set(identity['lockfile_sha256']) != {'pubspec.lock', 'assets/typescript/package-lock.json'}
            or not isinstance(archive, dict) or set(archive) != {'size', 'sha256'}
            or type(archive['size']) is not int or not 1 <= archive['size'] <= MAX_TOTAL):
        raise ValueError('Invalid expected source/archive identity')
    for item, width in [(identity['commit'], 40), (identity['tree'], 40),
            (value['file_set_sha256'], 64), (archive['sha256'], 64),
            *[(digest, 64) for digest in identity['lockfile_sha256'].values()]]:
        if not isinstance(item, str) or not re.fullmatch('[0-9a-f]{' + str(width) + '}', item):
            raise ValueError('Invalid identity digest')
    for key in ['run_id', 'run_attempt']:
        if not isinstance(value[key], str) or not re.fullmatch('[1-9][0-9]{0,19}', value[key]):
            raise ValueError('Invalid run identity')
    if (identity['commit'] != source or value['run_id'] != run_id or value['run_attempt'] != run_attempt):
        raise ValueError('Transport differs from current source/run/attempt')
    return value


def check_archive(archive, expected):
    if archive.name != ARCHIVE:
        raise ValueError('Unexpected transport archive filename')
    ordinary(archive, MAX_TOTAL)
    if archive.stat().st_size != expected['archive']['size']:
        raise ValueError('Transport archive size differs')
    if _sha256(archive) != expected['archive']['sha256']:
        raise ValueError('Transport archive digest differs')


def checkout_identity(source):
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
    env.update({'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'GIT_CONFIG_SYSTEM': os.devnull})
    return source_identity(source, environment=env)


def read_transport(archive, expected, source, output, *, registry_ready=False):
    if os.path.lexists(output):
        raise ValueError('Transport output already exists')
    if expected.get('schema_version') != (2 if registry_ready else 1):
        raise ValueError('Transport differs from explicit expected registry mode')
    check_archive(archive, expected)
    if checkout_identity(source) != expected['source']:
        raise ValueError('Transport source differs from actual checkout identity')
    # Snapshot authenticated compressed bytes once. Preflight and extraction
    # then read immutable owned temporary files, not a mutable downloaded path.
    with tempfile.TemporaryFile() as encoded, tempfile.TemporaryFile() as decoded:
        digest = hashlib.sha256(); count = 0
        with archive.open('rb') as incoming:
            while block := incoming.read(1024 * 1024):
                count += len(block)
                if count > MAX_TOTAL:
                    raise ValueError('Compressed transport exceeds bound')
                digest.update(block); encoded.write(block)
        if count != expected['archive']['size'] or digest.hexdigest() != expected['archive']['sha256']:
            raise ValueError('Transport changed before decoding')
        ordinary(archive, MAX_TOTAL)
        encoded.seek(0)
        expanded = 0
        with gzip.GzipFile(fileobj=encoded) as compressed:
            while block := compressed.read(1024 * 1024):
                expanded += len(block)
                if expanded > MAX_TOTAL:
                    raise ValueError('Expanded transport exceeds bound')
                decoded.write(block)
        decoded.seek(0)
        entries, metadata = {}, {}
        with tarfile.open(fileobj=decoded, mode='r:') as stream:
            for member in stream:
                name = member.name
                if (not canonical(name) or name in entries or len(entries) >= MAX_FILES + 2
                        or not (name in METADATA or (name == UPLOAD_ARCHIVE if registry_ready else name.startswith(PREFIX)))
                        or member.type != tarfile.REGTYPE or member.sparse is not None
                        or member.linkname or member.pax_headers or member.offset_data != member.offset + 512
                        or member.mode not in {0o644, 0o755} or not 0 <= member.size <= MAX_FILE):
                    raise ValueError('Unexpected transport member')
                with stream.extractfile(member) as payload:
                    if name in METADATA:
                        if member.size > MAX_JSON:
                            raise ValueError('Transport metadata exceeds bound')
                        data = payload.read()
                        metadata[name] = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)
                        digest = hashlib.sha256(data).hexdigest()
                    else:
                        digest = hashlib.file_digest(payload, 'sha256').hexdigest()
                entries[name] = (member, digest)
            # Reject hidden concatenated tar content after the first end marker.
            if expanded % 512 or expanded - stream.offset < 1024:
                raise ValueError('Missing tar end markers')
            decoded.seek(stream.offset)
            while block := decoded.read(1024 * 1024):
                if any(block):
                    raise ValueError('Nonzero data after tar end marker')
        if set(metadata) != METADATA:
            raise ValueError('Missing transport metadata')
        saved = metadata['stage-identity.json']
        if saved['source'] != expected['source'] or saved['file_set_sha256'] != expected['file_set_sha256']:
            raise ValueError('Archived stage identity differs from caller')
        files = saved['files']
        if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES:
            raise ValueError('Invalid archived stage inventory')
        if registry_ready:
            if (set(entries) != METADATA | {UPLOAD_ARCHIVE}
                    or saved.get('registry_ready') is not True
                    or saved.get('upload_archive') != expected['upload_archive']
                    or entries[UPLOAD_ARCHIVE][1] != expected['upload_archive']['sha256']
                    or entries[UPLOAD_ARCHIVE][0].size != expected['upload_archive']['size']):
                raise ValueError('Transport upload archive differs from caller identity')
        else:
            if set(entries) != {PREFIX + name for name in files} | METADATA:
                raise ValueError('Transport file set differs from stage identity')
            if any(entries[PREFIX + name][1] != value for name, value in files.items()):
                raise ValueError('Transport staged bytes differ from identity')
        output = output.parent.resolve() / output.name
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.pub-receive-', dir=output.parent) as temporary:
            result = Path(temporary) / 'result'
            result.mkdir()
            decoded.seek(0)
            with tarfile.open(fileobj=decoded, mode='r:') as stream:
                for name, (member, _) in entries.items():
                    path = result / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with stream.extractfile(member) as payload, path.open('xb') as destination:
                        shutil.copyfileobj(payload, destination)
                    if os.name != 'nt':
                        path.chmod(member.mode)
            if registry_ready:
                inspect_upload_archive(result / UPLOAD_ARCHIVE, files, result / PREFIX.rstrip('/'))
            checked = validate_evidence(result, expected['source'], registry_ready=registry_ready)
            if checked['file_set_sha256'] != expected['file_set_sha256']:
                raise ValueError('Materialized stage differs from caller')
            if checkout_identity(source) != expected['source']:
                raise ValueError('Checkout changed during transport materialization')
            result.rename(output)
    return {'scope': ('registry-candidate CI transport only' if registry_ready else 'private CI transport only'), 'transport': expected,
            'stage_evidence': str(output)}


def write_transport(evidence, source, expected_source, run_id, run_attempt, output, *, registry_ready=False):
    if os.path.lexists(output):
        raise ValueError('Transport output already exists')
    identity = checkout_identity(source)
    if identity['commit'] != expected_source:
        raise ValueError('Producer source differs from expected commit')
    saved = validate_evidence(evidence, identity, registry_ready=registry_ready)
    names = sorted(({UPLOAD_ARCHIVE} if registry_ready else
                    {PREFIX + name for name in saved['files']}) | METADATA)
    output = output.parent.resolve() / output.name
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pub-transport-', dir=output.parent) as temporary:
        root = Path(temporary)
        result = root / 'result'; result.mkdir()
        archive = result / ARCHIVE
        with archive.open('xb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.USTAR_FORMAT) as stream:
                for name in names:
                    path = evidence / name
                    ordinary(path, MAX_FILE)
                    member = tarfile.TarInfo(name)
                    member.size = path.stat().st_size
                    member.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                    with path.open('rb') as payload:
                        stream.addfile(member, payload)
        record = {'schema_version': 1, 'source': identity, 'file_set_sha256': saved['file_set_sha256'],
            'archive': {'size': archive.stat().st_size, 'sha256': _sha256(archive)},
            'run_id': run_id, 'run_attempt': run_attempt}
        if registry_ready:
            record.update(schema_version=2, registry_ready=True, upload_archive=saved['upload_archive'])
        record = expectation(json.dumps(record), expected_source, run_id, run_attempt, registry_ready=registry_ready)
        read_transport(archive, record, source, root / 'round-trip', registry_ready=registry_ready)
        (result / 'transport.json').write_text(json.dumps(record, sort_keys=True) + '\n', encoding='utf-8')
        result.rename(output)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    for operation in ['write', 'read']:
        sub = commands.add_parser(operation)
        sub.add_argument('--registry-ready', action='store_true')
        for name in ['source', 'output']:
            sub.add_argument('--' + name, type=lambda value: Path(value).absolute(), required=True)
        for name in ['expected-source', 'run-id', 'run-attempt']:
            sub.add_argument('--' + name, required=True)
        if operation == 'write':
            sub.add_argument('--stage-evidence', type=lambda value: Path(value).absolute(), required=True)
        else:
            sub.add_argument('--archive', type=lambda value: Path(value).absolute(), required=True)
            sub.add_argument('--expected-json', required=True)
    args = parser.parse_args()
    try:
        if args.operation == 'read':
            expected = expectation(args.expected_json, args.expected_source, args.run_id, args.run_attempt,
                                   registry_ready=args.registry_ready)
            result = read_transport(args.archive, expected, args.source, args.output, registry_ready=args.registry_ready)
        else:
            result = write_transport(args.stage_evidence, args.source, args.expected_source,
                                     args.run_id, args.run_attempt, args.output, registry_ready=args.registry_ready)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Pub stage transport failed: {error}\n')


if __name__ == '__main__':
    main()
