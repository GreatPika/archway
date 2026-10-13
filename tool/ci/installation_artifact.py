"""Private, single-writer CI transport of an already-tested installation.

This is a controlled round trip, not a general untrusted archive importer.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile
import tempfile


def _sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _inventory(bundle, expected):
    directories = {'.'}
    for name in expected:
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or path.as_posix() != name
                or '..' in path.parts or '\\' in name or ':' in name):
            raise ValueError(f'Noncanonical installation path: {name}')
        directories.update(parent.as_posix() for parent in path.parents)
    files = {}

    def visit(path):
        info = path.lstat()
        name = path.relative_to(bundle).as_posix()
        if (stat.S_ISLNK(info.st_mode)
                or getattr(info, 'st_file_attributes', 0)
                & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)):
            raise ValueError(f'Installation alias: {name}')
        if stat.S_ISDIR(info.st_mode):
            if name not in directories:
                raise ValueError(f'Unexpected installation directory: {name}')
            for child in sorted(path.iterdir()):
                visit(child)
        elif stat.S_ISREG(info.st_mode):
            if name not in expected:
                raise ValueError(f'Unexpected installation file: {name}')
            files[name] = {'sha256': _sha256(path), 'size': info.st_size,
                           'mode': stat.S_IMODE(info.st_mode)}
        else:
            raise ValueError(f'Special installation entry: {name}')

    visit(bundle)
    if set(files) != set(expected):
        raise ValueError('Missing installation files')
    return dict(sorted(files.items()))


def _round_trip(archive, root, files):
    root.mkdir()
    seen = set()
    with tarfile.open(archive, 'r:') as stream:
        for member in stream:
            expected = files.get(member.name)
            if (expected is None or member.name in seen or not member.isreg()
                    or member.size != expected['size']
                    or member.mode != expected['mode']):
                raise ValueError(f'Unexpected archive member: {member.name}')
            seen.add(member.name)
            path = root / member.name
            path.parent.mkdir(parents=True, exist_ok=True)
            with stream.extractfile(member) as source, path.open('xb') as output:
                output.write(source.read())
            if os.name != 'nt':
                path.chmod(member.mode)
    if _inventory(root, files) != files:
        raise ValueError('Transported installation differs from the manifest')


def export_installation(bundle, destination, expected, provenance, verify):
    """Expose archive/provenance only after the transported bundle passes verify."""
    destination = Path(destination).absolute()
    if os.path.lexists(destination):
        raise FileExistsError(f'Artifact destination already exists: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    files = _inventory(bundle, expected)
    with tempfile.TemporaryDirectory(prefix='.archway-artifact-',
                                     dir=destination.parent) as temporary:
        stage = Path(temporary)
        artifact = stage / 'artifact'
        artifact.mkdir()
        archive = artifact / 'installation.tar'
        with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT) as stream:
            for name in files:
                stream.add(bundle / name, arcname=name, recursive=False)
        with tempfile.TemporaryDirectory(prefix='archway-transport-') as transported:
            base = Path(transported).resolve()
            root = base / 'transported café installation'
            _round_trip(archive, root, files)
            verify(root, base)
        record = {**provenance, 'schema_version': 1, 'files': files,
                  'archive': {'name': archive.name, 'sha256': _sha256(archive)}}
        (artifact / 'provenance.json').write_text(
            json.dumps(record, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        if os.path.lexists(destination):
            raise FileExistsError(f'Artifact destination already exists: {destination}')
        artifact.rename(destination)


def source_identity(repo, environment=None):
    """Identify clean tracked sources, not ignored generated assets or caches."""
    import subprocess

    def git(*args):
        return subprocess.run(['git', '-C', str(repo), *args], check=True,
                              capture_output=True, text=True, env=environment).stdout.strip()

    if git('status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Artifact export requires clean tracked sources')
    return {'commit': git('rev-parse', 'HEAD'),
            'tree': git('rev-parse', 'HEAD^{tree}'),
            'lockfile_sha256': {
                name: _sha256(repo / name) for name in
                ['pubspec.lock', 'assets/typescript/package-lock.json']}}


def runtime_version(executable, cwd):
    """Observe a runtime in the same working directory used by its invocation."""
    import subprocess

    result = subprocess.run([str(executable), '--version'], check=True,
                            capture_output=True, text=True, timeout=30, cwd=cwd)
    return (result.stdout + result.stderr).strip()
