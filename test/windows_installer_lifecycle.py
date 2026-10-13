"""Run real installers in an explicitly disposable Windows user account.

Never run against a personal account. Registry/filesystem effects are real. This
checks engineering lifecycle only, not the downloaded-file GUI/trust route.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


CASES = ['install-old', 'upgrade-final', 'installed-command', 'remove',
         'foreign-preserved', 'raw-path-registry-types', 'preexisting-path-token',
         'foreign-root-refusal', 'foreign-command-refusal', 'duplicate-token-refusal',
         'root-junction-refusal', 'locked-stale-file-failure',
         'obsolete-directory-junction-uninstall']


def run_lifecycle(installer, upgrade, stale_file, inspect=None, run_command=None):
    if sys.platform != 'win32':
        raise ValueError('Native Windows is required; no lifecycle result was measured.')
    execute = run_command or subprocess.run
    installed_result = None
    stale = Path(stale_file)
    if stale.is_absolute() or '..' in stale.parts or ':' in stale_file:
        raise ValueError('--stale-file must be a safe relative payload path')
    if not any('..' in part for part in stale.parts):
        raise ValueError('--stale-file must include a literal double dot within a basename '
                     '(for example installer-probe..txt) to exercise inventory parsing')
    if stale.parent == Path('.'):
        raise ValueError('--stale-file must have a non-root parent directory')
    import winreg
    stale_name = stale.as_posix()
    root = Path(os.environ['LOCALAPPDATA']) / 'Programs/Archway'
    token = str(root / 'bin/windows-x64')
    owner = r'Software\Archway\Installer'
    if os.path.lexists(root):
        raise ValueError('Disposable account already contains an Archway directory.')
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner):
            raise ValueError('Disposable account already contains installer state.')
    except FileNotFoundError:
        pass
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
        try:
            original = winreg.QueryValueEx(key, 'Path')
        except FileNotFoundError:
            original = None

    def set_path(raw, kind):
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            winreg.SetValueEx(key, 'Path', 0, kind, raw)

    def read_path():
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            return winreg.QueryValueEx(key, 'Path')

    def read_owner():
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner) as key:
                result = {}
                for name in ('Root', 'PathToken'):
                    try:
                        result[name] = winreg.QueryValueEx(key, name)
                    except FileNotFoundError:
                        result[name] = None
                return result
        except FileNotFoundError:
            return None

    installed_by_test = False

    def run(path, success=True, expected_code=None):
        nonlocal installed_by_test
        result = execute([str(path.resolve()), '/VERYSILENT',
                                 '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
                                timeout=180)
        if success is not None:
            assert (result.returncode == 0) == success, result.returncode
        if expected_code is not None:
            assert result.returncode == expected_code, result.returncode
        if result.returncode == 0 and path in (installer, upgrade):
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner):
                installed_by_test = True
        return result

    def uninstall(success=True):
        nonlocal installed_by_test
        executables = list(root.glob('unins*.exe'))
        assert len(executables) == 1, executables
        ownership = read_owner()
        assert ownership and ownership['Root'] and Path(ownership['Root'][0]) == root, (
            'Cannot wait for an unverified installer ownership transition', ownership)
        deadline = time.monotonic() + 180
        result = run(executables[0], success=success)
        if result.returncode == 0:
            installed_by_test = False
            # Inno's first phase exits before the second phase deletes its EXE
            # and reaches usPostUninstall, which clears our ownership markers.
            while True:
                remaining = {'owner': read_owner(),
                             'uninstallers': [p.name for p in root.glob('unins*.exe')]}
                if not remaining['uninstallers'] and (
                        remaining['owner'] is None or
                        all(value is None for value in remaining['owner'].values())):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('Inno uninstall did not complete: ' + repr(remaining))
                time.sleep(0.05)
        return result

    try:
        # First lifecycle case: raw long expandable PATH and exact ownership
        # persistence across a real version upgrade, followed by later user edits.
        raw = '%SystemRoot%\\System32;' + ';'.join(
            f'C:\\unrelated spaced путь {i}' for i in range(250)) + ';;'
        for kind in (winreg.REG_SZ, winreg.REG_EXPAND_SZ):
            set_path(raw, kind)
            run(installer)
            expected = raw + ';' + token
            assert read_path() == (expected, kind)
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner) as key:
                assert winreg.QueryValueEx(key, 'PathToken')[0] == token
            old_files = json.loads((root / 'manifest.json').read_text())['files']
            run(upgrade)
            new_files = json.loads((root / 'manifest.json').read_text())['files']
            for name, entry in new_files.items():
                assert hashlib.sha256((root / name).read_bytes()).hexdigest() == entry['sha256']
            assert stale_name in old_files and stale_name not in new_files, (
                'Fixtures must exercise a real stale owned-file transition', stale_name)
            for name in old_files.keys() - new_files.keys():
                assert not (root / name).exists(), 'stale owned file remains'
            assert read_path() == (expected, kind), 'upgrade duplicated/reformatted PATH'
            later = ';C:\\later unrelated 雪'
            set_path(expected + later, kind)
            # Foreign file under installation root must survive standard uninstall.
            foreign = root / 'user-notes.txt'
            foreign.write_text('preserve me', encoding='utf-8')
            before_removal = {'path': read_path(), 'owner': read_owner()}
            uninstall()
            after_removal = {'path': read_path(), 'owner': read_owner()}
            # Only this controlled synthetic PATH, never the account's original
            # environment. Keep exact raw text and registry types on failure.
            assert after_removal['path'] == (raw + later, kind), {
                'case': 'raw-path-preservation-after-uninstall',
                'before': before_removal,
                'expected': {'path': (raw + later, kind)},
                'after': after_removal,
            }
            assert foreign.read_text(encoding='utf-8') == 'preserve me'
            foreign.unlink()
            # Inno removes only empty directories, so the mixed root can remain.
            root.rmdir()

        # Pre-existing equivalent token must never be adopted or removed.
        prior = '%SystemRoot%\\System32;"' + token.upper() + '\\";'
        set_path(prior, winreg.REG_EXPAND_SZ)
        run(installer)
        run(upgrade)
        assert read_path() == (prior, winreg.REG_EXPAND_SZ)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner) as key:
            try:
                winreg.QueryValueEx(key, 'PathToken')
                raise AssertionError('adopted pre-existing token')
            except FileNotFoundError:
                pass
        # Installed native process from another cwd, with no Node/Dart on PATH.
        with tempfile.TemporaryDirectory(prefix='Archway cwd путь ') as directory:
            env = dict(os.environ, PATH=os.environ['SystemRoot'] + '\\System32;' + token)
            command = execute([str(root / 'bin/windows-x64/archway.exe'), '--help'],
                                     cwd=directory, env=env, capture_output=True)
            assert command.returncode == 0, command.stderr
            discovery = execute([os.environ['SystemRoot'] + r'\System32\where.exe',
                                        'archway'], cwd=directory, env=env,
                                       capture_output=True, text=True)
            assert discovery.returncode == 0 and token.lower() in discovery.stdout.lower()
        if inspect is not None:
            installed_result = inspect(root / 'bin/windows-x64/archway.exe', root)
        uninstall()
        assert read_path() == (prior, winreg.REG_EXPAND_SZ)

        # Foreign root refusal before registration or file changes.
        root.mkdir(exist_ok=True)
        sentinel = root / 'foreign.txt'
        sentinel.write_text('untouched')
        before = read_path()
        run(installer, success=False)
        assert sentinel.read_text() == 'untouched' and read_path() == before
        sentinel.unlink()
        root.rmdir()

        # Foreign command refusal before creating the installation root.
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'archway.cmd').write_text('@exit /b 0')
            set_path(directory, winreg.REG_SZ)
            run(installer, success=False)
            assert read_path() == (directory, winreg.REG_SZ) and not root.exists()
        # A duplicate exact owned token cannot be safely attributed on removal.
        set_path(raw, winreg.REG_SZ)
        run(installer)
        duplicated = raw + ';' + token + ';' + token
        set_path(duplicated, winreg.REG_SZ)
        uninstall(success=False)
        assert read_path() == (duplicated, winreg.REG_SZ)
        assert (root / 'bin/windows-x64/archway.exe').exists()
        set_path(raw + ';' + token, winreg.REG_SZ)
        uninstall()

        # An NTFS junction at the root is refused without touching its target.
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / 'foreign.txt'
            sentinel.write_text('junction target survives')
            result = execute([os.environ['COMSPEC'], '/d', '/c', 'mklink',
                                     '/J', str(root), directory], capture_output=True)
            assert result.returncode == 0, result.stderr
            before = read_path()
            try:
                run(installer, success=False)
                assert sentinel.read_text() == 'junction target survives'
                assert read_path() == before
            finally:
                root.rmdir()  # Remove the junction only, never traverse its target.

        # Real post-install failure: allow reading the old stale bytes but deny
        # deletion while the upgrade tries its bounded stale-owned cleanup.
        set_path(raw, winreg.REG_SZ)
        run(installer)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
            wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
            wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.CreateFileW(str(root / stale), 0x80000000, 3, None, 3, 0x80, None)
        assert handle != wintypes.HANDLE(-1).value, ctypes.get_last_error()
        try:
            run(upgrade, success=False, expected_code=20)
            assert (root / stale).exists(), 'failure probe did not keep stale file locked'
        finally:
            assert kernel.CloseHandle(handle)
        uninstall()  # Standard Inno log retains the old generation's file entry.
        assert not (root / stale).exists()
        # The uninstaller retains historical entries even after upgrade removes
        # their bytes. Replace that obsolete directory with a foreign junction.
        run(installer)
        assert (root / stale).is_file()
        run(upgrade)
        assert not (root / stale).exists()
        obsolete = root / stale.parent
        assert obsolete != root, 'historical junction case needs a directory'
        if obsolete.exists():
            obsolete.rmdir()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            sentinel = target / stale.name
            sentinel.write_bytes(b'foreign historical-name sentinel')
            result = execute([os.environ['COMSPEC'], '/d', '/c', 'mklink',
                              '/J', str(obsolete), str(target)], capture_output=True)
            assert result.returncode == 0, result.stderr
            def assert_refusal_preserves_state():
                unchanged_path, unchanged_owner = read_path(), read_owner()
                preserved = {name: (root / name).read_bytes() for name in (
                    'bin/windows-x64/archway.exe', '.archway-owned-files.txt')}
                for action in (lambda: uninstall(success=False),
                               lambda: run(upgrade, success=False)):
                    action()
                    assert read_path() == unchanged_path
                    assert read_owner() == unchanged_owner
                    for name, contents in preserved.items():
                        assert (root / name).read_bytes() == contents
                    assert sentinel.read_bytes() == b'foreign historical-name sentinel'
                    assert list(target.iterdir()) == [sentinel]

            try:
                assert_refusal_preserves_state()
            finally:
                if os.path.lexists(obsolete):
                    obsolete.rmdir()  # Never traverse the foreign target.
            # A nested path absent from every generation's inventory must receive
            # the same protection, including Unicode names in native enumeration.
            unlisted = root / 'unlisted-雪'
            empty = unlisted / 'empty'
            empty.mkdir(parents=True)
            junction = unlisted / 'junction'
            result = execute([os.environ['COMSPEC'], '/d', '/c', 'mklink',
                              '/J', str(junction), str(target)], capture_output=True)
            assert result.returncode == 0, result.stderr
            try:
                assert_refusal_preserves_state()
            finally:
                if os.path.lexists(junction):
                    junction.rmdir()
            run(upgrade)  # Ordinary unlisted and empty directories are permitted.
            empty.rmdir()
            unlisted.rmdir()
            if list(root.glob('unins*.exe')):
                uninstall()
            assert sentinel.read_bytes() == b'foreign historical-name sentinel'
        return {'cases': list(CASES), 'installed': installed_result}
    finally:
        primary = sys.exception()
        if primary is not None and installed_by_test:
            try:
                # Only the successfully installed, registered root owned by this run.
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, owner):
                    uninstall()
            except Exception as cleanup:
                primary.add_note('Owned installer cleanup also failed: ' + repr(cleanup))
        # Test-account cleanup only; production uninstall never restores snapshots.
        try:
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                if original is None:
                    try:
                        winreg.DeleteValue(key, 'Path')
                    except FileNotFoundError:
                        pass
                else:
                    winreg.SetValueEx(key, 'Path', 0, original[1], original[0])
        except Exception as cleanup:
            if primary is None:
                raise
            primary.add_note('Test PATH restoration also failed: ' + repr(cleanup))



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installer', required=True, type=Path)
    parser.add_argument('--upgrade', required=True, type=Path)
    parser.add_argument('--stale-file', required=True)
    parser.add_argument('--disposable-account', action='store_true', required=True)
    args = parser.parse_args()
    run_lifecycle(args.installer, args.upgrade, args.stale_file)
    print('Native lifecycle passed; desktop GUI acceptance remains pending.')


if __name__ == '__main__':
    main()
