"""Host-native library layout and compiler commands for CLI fault probes."""
from pathlib import Path
import os
import tempfile
import platform
import subprocess


def native_target():
    host = (platform.system(), platform.machine().lower())
    targets = {
        ('linux', 'x86_64'): ('linux-x64', 'libarchway_io.so', 'linux_io.c'),
        ('darwin', 'arm64'): ('macos-arm64', 'libarchway_io.dylib', 'macos_io.c'),
        ('windows', 'amd64'): ('windows-x64', 'archway_io.dll', 'windows_io.c'),
    }
    selected = targets.get((host[0].lower(), host[1]))
    if selected is None:
        raise ValueError(f'Unsupported native probe host: {host}')
    return selected


def build_library(source, destination):
    target, _, _ = native_target()
    repository = Path(__file__).resolve().parents[1]
    if target == 'macos-arm64':
        command = ['xcrun', '--sdk', 'macosx', 'clang', '-arch', 'arm64',
                   '-mmacosx-version-min=15.0', '-std=c11', '-O2', '-Wall',
                   '-Wextra', '-Werror', '-dynamiclib',
                   '-Wl,-install_name,@rpath/libarchway_io.dylib']
    elif target == 'linux-x64':
        command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC']
    else:
        return build_windows_library(source, destination, repository)
    subprocess.run([*command, '-I', str(repository / 'native'), str(source),
                    '-o', str(destination)], check=True, timeout=60)


def build_windows_library(source, destination, repository):
    # Match the installed, pinned production builder. No downloads or ambient
    # compiler options; these fixtures are owned test sources, never projects.
    program_files = Path(os.environ['ProgramFiles(x86)'])
    vswhere = program_files / 'Microsoft Visual Studio/Installer/vswhere.exe'
    installation = subprocess.run([str(vswhere), '-latest', '-products', '*',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'], check=True, capture_output=True,
        text=True, timeout=15).stdout.strip()
    if not installation:
        raise ValueError('Installed Visual Studio x64 tools are missing')
    msvc = Path(installation) / 'VC/Tools/MSVC/14.44.35207'
    sdk = program_files / 'Windows Kits/10'
    version = '10.0.26100.0'
    binary = msvc / 'bin/Hostx64/x64'
    includes = [msvc / 'include', *[sdk / 'Include' / version / name
                                   for name in ('ucrt', 'shared', 'um')]]
    libraries = [msvc / 'lib/x64', *[sdk / 'Lib' / version / name / 'x64'
                                    for name in ('ucrt', 'um')]]
    for path in [binary / 'cl.exe', binary / 'link.exe', *includes, *libraries]:
        if not path.exists():
            raise ValueError(f'Pinned Windows native fixture input is missing: {path}')
    environment = {key: value for key, value in os.environ.items()
                   if key.upper() not in {'CL', '_CL_', 'LINK', '_LINK_', 'INCLUDE', 'LIB'}}
    environment.update(PATH=str(binary) + os.pathsep + environment.get('PATH', ''),
                       INCLUDE=os.pathsep.join(map(str, includes)),
                       LIB=os.pathsep.join(map(str, libraries)))
    with tempfile.TemporaryDirectory(prefix='archway-native-compiler-') as temp:
        work = Path(temp)
        subprocess.run([str(binary / 'cl.exe'), '/nologo', '/std:c11', '/O2',
            '/W4', '/WX', '/MT', '/LD', '/TC', '/I' + str(repository / 'native'),
            str(source), '/Fo' + str(work / 'fixture.obj'), '/Fe' + str(destination),
            '/link', '/MACHINE:X64', '/DYNAMICBASE', '/NXCOMPAT', '/INCREMENTAL:NO',
            '/IMPLIB:' + str(work / 'fixture.lib'), 'ntdll.lib', 'kernel32.lib'],
            env=environment, cwd=work, check=True, timeout=60)
