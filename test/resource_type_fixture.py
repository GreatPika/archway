"""Native non-file resources without volume or privilege changes."""
import os


def nonregular_resource(path):
    if os.name == 'nt':
        # Windows has no POSIX filesystem FIFO; a directory is a real non-file
        # resource at the exact SDK/analyzer input path, never a missing file.
        path.mkdir()
    else:
        os.mkfifo(path)


def remove_nonregular_resource(path):
    if os.name == 'nt':
        path.rmdir()
    else:
        path.unlink()
