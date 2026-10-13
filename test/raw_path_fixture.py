"""Malformed *native* filenames: UTF-16 on Windows, UTF-8 bytes on POSIX."""
import os


def malformed_path(parent, name, *, windows=None):
    if windows is None:
        windows = os.name == 'nt'
    if windows:
        # NTFS can store an unpaired UTF-16 surrogate. Passing a wide string
        # preserves the invalid unit rather than manufacturing a U+FFFD name.
        return os.path.join(str(parent), name + '\udcff')
    return os.fsencode(parent) + os.fsencode(os.sep + name) + b'\xff'
