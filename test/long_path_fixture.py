"""Create long native fixture paths without modifying Windows system policy."""
import ntpath
import os
from pathlib import Path
import shutil


def fixture_path(path, *, windows=None):
    if windows is None:
        windows = os.name == 'nt'
    if not windows:
        return Path(path)
    value = str(path)
    if value.startswith('\\\\?\\'):
        return Path(value)
    drive, tail = ntpath.splitdrive(value)
    if not drive or not tail.startswith(('\\', '/')):
        raise ValueError('A Windows long fixture path must be absolute')
    value = ntpath.normpath(value)
    if value.startswith('\\\\'):
        return Path('\\\\?\\UNC\\' + value[2:])
    return Path('\\\\?\\' + value)


def remove_fixture_tree(path):
    native = fixture_path(path)
    if native.exists():
        shutil.rmtree(native)
