"""Extract only the committed, offline npm/pnpm snapshots for native tests."""
import os
from pathlib import Path, PurePosixPath
import posixpath
import sys
import tarfile


def archive_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or "\\" in value or ":" in value:
        raise ValueError(f'Non-relative archive path: {value}')
    normalized = posixpath.normpath(value)
    if normalized == '..' or normalized.startswith('../'):
        raise ValueError(f'Archive path escapes destination: {value}')
    return normalized


def extract_node_fixture(archive, destination):
    destination = Path(destination)
    if destination.is_symlink() or destination.is_junction():
        raise ValueError('Fixture destination must be an ordinary directory')
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        by_name = {}
        links = []
        for member in members:
            name = archive_path(member.name)
            if '..' in PurePosixPath(member.name).parts or name in by_name:
                raise ValueError(f'Ambiguous archive member: {member.name}')
            by_name[name] = member
            if member.issym():
                links.append(member)
            elif not (member.isdir() or member.isfile() or member.islnk()):
                raise ValueError(f'Unsupported archive member: {member.name}')
        for name, member in by_name.items():
            parts = PurePosixPath(name).parts
            for count in range(1, len(parts) + 1):
                parent = '/'.join(parts[:count])
                if count < len(parts) and by_name.get(parent) is not None and by_name[parent].issym():
                    raise ValueError(f'Archive member traverses an alias: {name}')
                existing = destination / Path(*parts[:count])
                if existing.is_symlink() or existing.is_junction():
                    raise ValueError(f'Destination traverses an alias: {name}')
            if member.issym():
                # All links in these finite manager snapshots are directories.
                # Preserve relative dot segments, changing only native separators.
                if PurePosixPath(member.linkname).is_absolute() or "\\" in member.linkname or ':' in member.linkname:
                    raise ValueError(f'Invalid symbolic link target: {name}')
                target = archive_path(posixpath.join(posixpath.dirname(name), member.linkname))
                if target not in by_name or not by_name[target].isdir():
                    raise ValueError(f'Symbolic link target is not an archived directory: {name}')
            elif member.islnk():
                target = archive_path(member.linkname)
                if target not in by_name or not by_name[target].isfile():
                    raise ValueError(f'Hard link target is not an archived file: {name}')
        # Materialize directories/files/hardlinks before creating any symlinks.
        # tarfile's default symlink call omits Windows' directory flag, and raw
        # POSIX separators in relative Windows reparse targets are not traversable.
        destination.mkdir(parents=True, exist_ok=True)
        bundle.extractall(destination, members=[m for m in members if not m.issym()],
                          filter='fully_trusted')
        for member in links:
            link = destination / Path(*PurePosixPath(member.name).parts)
            target = member.linkname.replace('/', os.sep)
            os.symlink(target, link, target_is_directory=True)
            expected = link.parent / Path(*PurePosixPath(member.linkname).parts)
            if (not link.is_symlink() or os.readlink(link) != target or
                    not link.is_dir() or link.resolve(strict=True) != expected.resolve(strict=True)):
                raise RuntimeError(f'Prepared package link is not traversable: {link}')


if __name__ == '__main__':
    extract_node_fixture(*sys.argv[1:3])
