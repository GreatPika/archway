"""Copy the actual assembled installation before a process test tampers with it."""
from pathlib import Path
import shutil


def stage_installation(executable, destination):
    executable = Path(executable).resolve()
    source = executable.parents[2]
    relative = executable.relative_to(source)
    assert relative in (Path('bin/linux-x64/archway'),
                        Path('bin/macos-arm64/archway'),
                        Path('bin/macos-universal/archway'),
                        Path('bin/windows-x64/archway.exe')), relative
    binary = destination / relative
    binary.parent.mkdir(parents=True)
    shutil.copy2(executable, binary)
    for directory in ['native', 'assets']:
        shutil.copytree(source / directory, destination / directory, symlinks=True)
    return binary
