"""One exact private pub-stage validator shared by producer and CI consumer."""
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile

from combine_installations import MAX_FILE, MAX_FILES, MAX_TOTAL, PAYLOADS, canonical, ordinary, read_record
from installation_artifact import _inventory, _sha256


def validate_pub_advisories(stdout, stderr, exit_code, *, export=False):
    """Accept only the seven reviewed Dart 3.13.3 tight-pin advisories."""
    pins = [('analyzer', '14.5.0'), ('package_config', '2.2.0'),
            ('pub_semver', '2.2.1'), ('crypto', '3.0.7'), ('yaml', '3.1.4'),
            ('path', '1.9.1'), ('unorm_dart', '0.3.2')]
    heading = 'Package validation found the following 7 potential issues:\n'
    if stderr.strip() or exit_code != (0 if export else 65) or stdout.count(heading) != 1:
        raise ValueError('Unexpected pub validation status or diagnostics')
    before, after = stdout.split(heading)
    expected = ''.join(
        f'* Your dependency on "{name}" should allow more than one version. For example:\n'
        f'  \n  dependencies:\n    {name}: ^{version}\n  \n'
        '  Constraints that are too tight will make it difficult for people to use your package\n'
        f'  along with other packages that also depend on "{name}".\n\n'
        for name, version in pins).rstrip('\n') + '\n'
    preamble = re.fullmatch(
        r'Resolving dependencies\.\.\.\nDownloading packages\.\.\.\n'
        r'(?P<updates>(?:  [a-z][a-z0-9_]* [0-9][0-9A-Za-z.+-]* '
        r'\([0-9][0-9A-Za-z.+-]* available\)\n)*)Got dependencies!\n'
        r'(?:(?P<count>[1-9][0-9]*) packages? ha(?:ve|s) newer versions incompatible with dependency constraints\.\n'
        r'Try `dart pub outdated` for more information\.\n)?'
        r'Publishing archway 0\.1\.0 to https://pub\.dev:\n'
        r'(?:(?:│   |    )*[├└]── [^\r\n]+\n)+\n'
        r'Total compressed archive size: (?:<1|[0-9]+(?:\.[0-9]+)?) (?:B|KB|MB)\.\n'
        r'Validating package\.\.\.\n', before)
    if (not after.startswith(expected) or preamble is None
            or len(preamble['updates'].splitlines()) != int(preamble['count'] or 0)):
        raise ValueError('Pub advisories or preamble differ from the reviewed pinned format')
    tail = after[len(expected):].strip()
    if export:
        valid_tail = re.fullmatch(r'Wrote package archive at [^\r\n]+', tail)
    else:
        valid_tail = tail == 'The server may enforce additional checks.\n\nPackage has 7 warnings.'
    if not valid_tail:
        raise ValueError('Unexpected additional pub validation diagnostics')
    return {'exit_code': exit_code, 'expected_advisories': 7}


def validate_stage(stage, expected, *, registry_ready=False):
    manifest = read_record(stage / 'manifest.json')
    if (set(manifest) != {'private', 'partial', 'targets', 'versions', 'sha256'}
            or manifest['private'] is not (not registry_ready) or manifest['partial'] is not False
            or manifest['targets'] != list(PAYLOADS)
            or manifest['versions'] != {'archway': '0.1.0', 'dart': '3.13.3',
                'node': '24.21.0', 'typescript': '5.9.3', 'yaml': '2.8.1'}):
        raise ValueError('Not the expected all-target pub manifest')
    if (not isinstance(expected, dict) or not 1 <= len(expected) < MAX_FILES
            or 'manifest.json' in expected or manifest['sha256'] != expected
            or any(not canonical(name) or not isinstance(digest, str)
                   or not re.fullmatch('[0-9a-f]{64}', digest) for name, digest in expected.items())):
        raise ValueError('Pub manifest differs from reviewed source/audited assets')
    files = {**expected, 'manifest.json': _sha256(stage / 'manifest.json')}
    inventory = _inventory(stage, files)
    if sum(entry['size'] for entry in inventory.values()) > MAX_TOTAL:
        raise ValueError('Pub stage exceeds bound')
    for name, entry in inventory.items():
        if entry['size'] > MAX_FILE or entry['sha256'] != files[name]:
            raise ValueError('Pub stage differs from complete canonical inventory')
    spec = (stage / 'pubspec.yaml').read_text(encoding='utf-8')
    destination = 'https://pub.dev' if registry_ready else 'none'
    for line in ['name: archway', 'version: 0.1.0', 'publish_to: ' + destination]:
        if spec.splitlines().count(line) != 1:
            raise ValueError('Unexpected pub metadata')
    if not re.search(r'^executables:\n  archway:\s*\Z', spec, re.MULTILINE):
        raise ValueError('Unexpected executable mapping')
    required = {'bin/archway.dart', 'bin/setup.dart', *['native/' + target + '/' + bridge
                for target, (_, bridge) in PAYLOADS.items()],
                *['assets/typescript/' + name for name in [
                    'vendor/typescript/lib/lib.es2022.d.ts',
                    'vendor/typescript/LICENSE.txt', 'vendor/yaml/LICENSE',
                    'licenses/pnpm-MIT.txt', 'licenses/yaml-ISC.txt']]}
    if registry_ready:
        required |= {'LICENSE', 'README.md', 'CHANGELOG.md'}
    if not required <= files.keys():
        raise ValueError('Missing required pub source, bridge or redistribution asset')
    return {'files': files, 'file_set_sha256': hashlib.sha256(
        json.dumps(files, sort_keys=True).encode()).hexdigest()}


def validate_evidence(evidence, source, *, registry_ready=False):
    saved = read_record(evidence / 'stage-identity.json')
    report = read_record(evidence / 'report.json')
    if saved['source'] != source or report['source'] != source:
        raise ValueError('Stage source differs from actual checkout identity')
    checked = validate_stage(evidence / 'pub source café', {
        name: digest for name, digest in saved['files'].items() if name != 'manifest.json'},
        registry_ready=registry_ready)
    if (saved['files'] != checked['files'] or saved['file_set_sha256'] != checked['file_set_sha256']
            or report['file_set_sha256'] != checked['file_set_sha256']
            or report['files'] != len(checked['files'])):
        raise ValueError('Stage identity/report differs from exact inventory')
    if registry_ready:
        if (saved.get('registry_ready') is not True or report.get('registry_ready') is not True
                or report.get('dry_run') != {'exit_code': 65, 'expected_advisories': 7}
                or report.get('archive_export') != {'exit_code': 0, 'expected_advisories': 7}
                or any(type(value) is not int for phase in ('dry_run', 'archive_export')
                       for value in report[phase].values())):
            raise ValueError('Candidate evidence lacks reviewed validation results')
        archive = inspect_upload_archive(evidence / UPLOAD_ARCHIVE, checked['files'])
        if saved.get('upload_archive') != archive or report.get('upload_archive') != archive:
            raise ValueError('Candidate upload archive differs from validation evidence')
    return saved


# Conservative candidate budgets from Dart publishing guidance, not server guarantees.
PUB_COMPRESSED_LIMIT = 100_000_000
PUB_EXPANDED_LIMIT = 256_000_000
UPLOAD_ARCHIVE = 'pub-package.tar.gz'


def inspect_upload_archive(archive, files, output=None):
    """Verify pinned pub's archive dialect and exact files before optional extraction."""
    ordinary(archive, PUB_COMPRESSED_LIMIT - 1)
    if (not isinstance(files, dict) or not 1 <= len(files) < MAX_FILES
            or any(not canonical(name) or not isinstance(digest, str)
                   or not re.fullmatch('[0-9a-f]{64}', digest) for name, digest in files.items())):
        raise ValueError('Invalid pub upload inventory')
    if output is not None and os.path.lexists(output):
        raise ValueError('Pub upload extraction output already exists')
    directories = {parent.as_posix() for name in files for parent in PurePosixPath(name).parents} - {'.'}
    with tempfile.TemporaryFile() as encoded, tempfile.TemporaryFile() as decoded:
        digest = hashlib.sha256(); size = 0
        with archive.open('rb') as source:
            while block := source.read(1024 * 1024):
                size += len(block)
                if size >= PUB_COMPRESSED_LIMIT:
                    raise ValueError('Pub compressed archive exceeds candidate budget')
                digest.update(block); encoded.write(block)
        encoded.seek(0); expanded = 0
        with gzip.GzipFile(fileobj=encoded) as compressed:
            while block := compressed.read(1024 * 1024):
                expanded += len(block)
                if expanded >= PUB_EXPANDED_LIMIT:
                    raise ValueError('Pub expanded archive exceeds candidate budget')
                decoded.write(block)
        decoded.seek(0); entries = {}; seen_files = set(); unpacked = 0
        with tarfile.open(fileobj=decoded, mode='r:') as stream:
            for member in stream:
                name = member.name
                if (not canonical(name) or name in entries or len(entries) >= MAX_FILES
                        or member.sparse is not None or member.linkname or member.pax_headers
                        or member.offset_data != member.offset + 512):
                    raise ValueError('Unexpected pub upload member')
                if member.type == tarfile.DIRTYPE:
                    if name not in directories or member.size != 0 or member.mode != 0o755:
                        raise ValueError('Unexpected pub upload directory')
                elif member.type == tarfile.REGTYPE:
                    if name not in files or not 0 <= member.size <= MAX_FILE or member.mode not in {0o644, 0o755}:
                        raise ValueError('Unexpected pub upload file')
                    with stream.extractfile(member) as payload:
                        if hashlib.file_digest(payload, 'sha256').hexdigest() != files[name]:
                            raise ValueError('Pub upload bytes differ from staged identity')
                    seen_files.add(name); unpacked += member.size
                else:
                    raise ValueError('Nonordinary pub upload member')
                entries[name] = member
            if expanded % 512 or expanded - stream.offset < 1024:
                raise ValueError('Missing pub upload tar end markers')
            decoded.seek(stream.offset)
            while block := decoded.read(1024 * 1024):
                if any(block):
                    raise ValueError('Nonzero data after pub upload tar end marker')
        if seen_files != files.keys():
            raise ValueError('Pub upload file set differs from staged identity')
        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.pub-upload-', dir=output.parent) as temporary:
                stage = Path(temporary) / 'stage'; stage.mkdir()
                decoded.seek(0)
                with tarfile.open(fileobj=decoded, mode='r:') as stream:
                    for name in sorted(seen_files):
                        member = entries[name]; path = stage / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        with stream.extractfile(member) as source, path.open('xb') as target:
                            shutil.copyfileobj(source, target)
                        if os.name != 'nt':
                            path.chmod(member.mode)
                stage.rename(output)
    return {'sha256': digest.hexdigest(), 'size': size, 'unpacked_bytes': unpacked,
            'files': len(seen_files)}
