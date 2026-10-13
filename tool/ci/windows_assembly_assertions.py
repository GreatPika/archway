"""Real Windows maintainer-assembler refusal/cleanup regressions, without rebuilds."""
import os
import shutil
import stat
import subprocess


def assert_windows_assembly_guards(repo, powershell, dart, base):
    def assemble(source_root, output):
        result = subprocess.run([
            powershell, '-NoProfile', '-File',
            str(source_root / 'tool/assemble_windows.ps1'),
            '-Output', str(output), '-Dart', str(dart),
        ], cwd=base, capture_output=True, timeout=30)
        print(f'Assembler refusal exit: {result.returncode}')
        print(f'Assembler stdout: {result.stdout!r}')
        print(f'Assembler stderr: {result.stderr!r}')
        assert result.returncode != 0, 'Assembler must refuse this unsafe/incomplete request.'
        return result

    # A caller-owned destination must remain byte-for-byte untouched.
    existing = base / 'existing output café'
    existing.mkdir()
    sentinel = existing / 'keep ü.txt'
    sentinel.write_bytes(b'Caller-owned output must not be overwritten.\n')
    before = set(base.iterdir())
    result = assemble(repo, existing)
    assert b'Assembly output already exists' in result.stderr
    assert list(existing.iterdir()) == [sentinel]
    assert sentinel.read_bytes() == b'Caller-owned output must not be overwritten.\n'
    assert set(base.iterdir()) == before
    print('WINDOWS_ASSEMBLY_EXISTING_OUTPUT_REFUSED')

    # Use a real local junction, then verify the OS tag before testing refusal.
    target = base / 'real output parent ü'
    target.mkdir()
    alias = base / 'aliased output parent café'
    subprocess.run([
        powershell, '-NoProfile', '-Command',
        "$ErrorActionPreference = 'Stop'; "
        'New-Item -ItemType Junction -Path $env:ARCHWAY_ASSEMBLY_ALIAS '
        '-Target $env:ARCHWAY_ASSEMBLY_TARGET | Out-Null',
    ], cwd=base, env={**os.environ, 'ARCHWAY_ASSEMBLY_ALIAS': str(alias),
                     'ARCHWAY_ASSEMBLY_TARGET': str(target)}, check=True, timeout=30)
    try:
        info = alias.lstat()
        assert info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT
        assert info.st_reparse_tag == stat.IO_REPARSE_TAG_MOUNT_POINT
        assert alias.resolve(strict=True) == target.resolve(strict=True)
        print(f'WINDOWS_ASSEMBLY_JUNCTION_READY tag={info.st_reparse_tag:#x}')
        before = set(base.iterdir())
        result = assemble(repo, alias / 'refused installation')
        assert b'Assembly path is a reparse point' in result.stderr
        assert list(target.iterdir()) == []
        assert set(base.iterdir()) == before
        print('WINDOWS_ASSEMBLY_ALIASED_PARENT_REFUSED')
    finally:
        # Remove only this invocation's junction, never traverse its target.
        alias.rmdir()

    # A private source copy lacks licenses; failure must leave no staging debris.
    # Never rename/delete assets in the real checkout, or fake compiler output.
    fixture = base / 'incomplete owned sources café'
    for relative in ['tool/assemble_windows.ps1', 'tool/build_native_windows.ps1',
                     'bin/archway.dart']:
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / relative, destination)
    assets = fixture / 'assets/typescript'
    shutil.copytree(repo / 'assets/typescript', assets)
    shutil.rmtree(assets / 'licenses')
    parent = base / 'failed assembly output ü'
    parent.mkdir()
    failed_output = parent / 'installation'
    result = assemble(fixture, failed_output)
    assert b'licenses' in result.stderr
    assert not failed_output.exists()
    assert list(parent.iterdir()) == [], 'Failed assembly must clean its stage and build scratch.'
    print('WINDOWS_ASSEMBLY_FAILURE_CLEANUP_PASSED')
