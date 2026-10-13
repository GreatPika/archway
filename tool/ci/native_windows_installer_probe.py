"""Native Windows installer measurement from an independently verified bundle.

Consumes immutable verified bytes; does not download/provision the compiler.
Use only an explicitly disposable Windows x64 CI account.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STALE = 'obsolete/installer-probe..txt'


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare_old_fixture(bundle, old):
    if (bundle / 'obsolete').exists():
        raise ValueError('Final bundle conflicts with obsolete fixture directory')
    shutil.copytree(bundle, old)
    stale = old / STALE
    stale.parent.mkdir()
    stale.write_bytes(b'Test-only previous-generation owned file.\n')
    manifest = json.loads((old / 'manifest.json').read_text(encoding='utf-8'))
    manifest['version'] = '0.0.0'
    manifest['files'][STALE] = {'mode': 0o644, 'size': stale.stat().st_size,
                               'sha256': sha256(stale)}
    (old / 'manifest.json').write_text(json.dumps(manifest) + '\n', encoding='utf-8')


def run_windows(bundle, output, inspect):
    if sys.platform != 'win32' or platform.machine().lower() not in ('amd64', 'x86_64'):
        raise ValueError('Native Windows x64 is required; no installer acceptance measured')
    bundle, output = bundle.absolute(), output.absolute()
    if (output.resolve() != output or output.is_relative_to(bundle.resolve())
            or os.path.lexists(output)):
        raise ValueError('Installer output must be fresh, canonical and outside bundle')
    compiler = compiler_path()
    output.mkdir(parents=True)
    commands = []

    def run(arguments, **kwargs):
        kwargs.pop('capture_output', None)
        text_mode = kwargs.pop('text', False)
        timeout = None
        try:
            result = subprocess.run(list(map(str, arguments)), capture_output=True,
                                    **{'timeout': 240, **kwargs})
        except subprocess.TimeoutExpired as error:
            timeout = error
            result = subprocess.CompletedProcess(arguments, -1, error.stdout or b'', error.stderr or b'')
        index = len(commands)
        stdout = output / f'windows-{index}.stdout.log'
        stderr = output / f'windows-{index}.stderr.log'
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        commands.append({'arguments': list(map(str, arguments)), 'exit': result.returncode,
                         'stdout': stdout.name, 'stderr': stderr.name,
                         'stdout_sha256': sha256(stdout), 'stderr_sha256': sha256(stderr)})
        if timeout is not None:
            raise timeout
        if text_mode:
            result.stdout = result.stdout.decode(errors='replace')
            result.stderr = result.stderr.decode(errors='replace')
        return result

    # ISCC's PE resource can be 0.0.0.0; /? only names the major version.
    # A fixed stdin script with /O- gets the engine's authoritative self-report
    # without emitting an installer. Both switches are supported by Inno 6.3.
    version_result = run([compiler, '/O-', '-'],
                         input=b'[Setup]\nAppName=Archway compiler preflight\nAppVersion=0\n'
                               b'CreateAppDir=no\nUninstallable=no\nOutput=no\n')
    if version_result.returncode:
        raise ValueError('Preinstalled Inno Setup compiler preflight failed')
    version = compiler_version(version_result.stdout)
    compiler_identity = {'path': str(compiler), 'sha256': sha256(compiler), 'version': version}
    artifact = output / 'archway-0.1.0-windows-x64-unsigned.exe'
    before = {p.relative_to(bundle).as_posix(): sha256(p)
              for p in bundle.rglob('*') if p.is_file()}
    manifest = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('version') != '0.1.0':
        raise ValueError('Final installer requires the verified 0.1.0 bundle')

    def inspect_verified(binary, installed):
        for name, digest in before.items():
            path = installed / name
            if path.is_symlink() or sha256(path) != digest:
                raise ValueError('Installed Windows payload differs: ' + name)
        return inspect(binary, installed)

    with tempfile.TemporaryDirectory(prefix='archway installer ') as temporary:
        base = Path(temporary).resolve()
        old = base / 'test-only-old-bundle'
        prepare_old_fixture(bundle, old)
        for payload, label, app_version in ((old, 'old', '0.0.0'), (bundle, 'final', '0.1.0')):
            prepared = base / (label + '-input')
            result = run([sys.executable, ROOT / 'tool/installers/windows/prepare.py',
                          payload, prepared])
            if result.returncode:
                raise ValueError('Windows installer preparation failed: ' + label)
            destination = base / 'old-artifact' if label == 'old' else output
            result = run([compiler, '/DAppVersion=' + app_version,
                          '/DOutputDir=' + str(destination), prepared / 'archway.iss'])
            if result.returncode:
                raise ValueError('Windows installer compilation failed: ' + label)
        old_exe = base / 'old-artifact/archway-0.0.0-windows-x64-unsigned.exe'
        old_identity = {'version': '0.0.0', 'test_only': True, 'removed_file': STALE,
                        'manifest_sha256': sha256(old / 'manifest.json'),
                        'artifact_sha256': sha256(old_exe)}
        spec = importlib.util.spec_from_file_location('windows_installer_lifecycle',
                                                     ROOT / 'test/windows_installer_lifecycle.py')
        lifecycle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lifecycle)
        receipt = lifecycle.run_lifecycle(old_exe, artifact, STALE, inspect_verified, run)
    after = {p.relative_to(bundle).as_posix(): sha256(p)
             for p in bundle.rglob('*') if p.is_file()}
    if after != before:
        raise ValueError('Verified bundle bytes changed')
    return {'artifact': {'name': artifact.name, 'sha256': sha256(artifact),
                         'size': artifact.stat().st_size},
            'compiler': compiler_identity, 'old_fixture': old_identity,
            'cases': receipt['cases'], 'installed': receipt['installed'], 'commands': commands}


def compiler_path():
    program_files = os.environ.get('ProgramFiles(x86)')
    if not program_files:
        raise ValueError('Preinstalled official Inno Setup 6 compiler is required')
    path = Path(program_files) / 'Inno Setup 6/ISCC.exe'
    if not path.is_file() or path.is_symlink():
        raise ValueError('Preinstalled official Inno Setup 6 compiler is required')
    return path


def compiler_version(output):
    lines = [line for line in output.splitlines()
             if line.startswith(b'Compiler engine version:')]
    match = (re.fullmatch(rb'Compiler engine version: Inno Setup (\d+)\.(\d+)\.(\d+)',
                          lines[0]) if len(lines) == 1 else None)
    if not match or tuple(int(value) for value in match.groups()) < (6, 3, 0):
        raise ValueError('Inno Setup 6.3 or newer is required; invalid or unsupported engine version')
    return '.'.join(str(int(value)) for value in match.groups())
