"""Destructive controls against disposable installed bytes, always caller-bound."""
from npm_local_analysis import assert_result, snapshot


def exercise(shim, root, cwd, installed, environment, run, target):
    cases = []

    def check(name, error="TYPESCRIPT_ASSETS_UNAVAILABLE"):
        before = snapshot(root), snapshot(cwd), snapshot(installed)
        result = run([str(shim), '--root', str(root), 'check'], cwd, environment,
                     expected_exit=2)
        value = assert_result(result, 2, 'incomplete')
        assert value['payload']['analysis_complete'] is False
        assert [e['code'] for e in value['payload']['tool_errors']] == [error]
        assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
        cases.append({'case': name, 'exit': 2, 'error': error})

    for name, relative in [('helper', 'assets/typescript/helper.cjs'),
                           ('compiler', 'assets/typescript/vendor/typescript/lib/typescript.js')]:
        asset = installed / relative
        saved = asset.with_suffix(asset.suffix + '.control-saved')
        assert not saved.exists()
        before = snapshot(installed)
        asset.rename(saved)
        try:
            if name == 'compiler':
                check('missing-compiler')
            # Real file symlinks on every host; inability to create one is a
            # failed acceptance prerequisite, never a passed or skipped case.
            asset.symlink_to(saved.name)
            assert asset.is_symlink() and asset.resolve() == saved
            check('aliased-' + name)
        finally:
            if asset.is_symlink():
                asset.unlink()
            saved.rename(asset)
        assert snapshot(installed) == before, 'Installed bytes not restored'
        original = asset.read_bytes()
        try:
            asset.write_bytes(b'this is not JavaScript!')
            check('corrupt-' + name, 'TYPESCRIPT_HELPER_FAILED' if name == 'helper'
                  else 'TYPESCRIPT_LOAD_FAILED')
        finally:
            asset.write_bytes(original)
        assert snapshot(installed) == before, 'Corrupt asset was not restored'
    binary = installed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')

    def prelaunch(name):
        before = snapshot(root), snapshot(cwd), snapshot(installed)
        result = run([str(shim), '--help'], cwd, environment, expected_exit=126)
        assert result.stdout == b'' and result.stderr.startswith(b'archway launcher:')
        assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
        cases.append({'case': name, 'exit': 126, 'error': 'launcher-prelaunch'})

    for name, asset in [('payload', binary), ('manifest', installed / 'manifest.json')]:
        saved = asset.with_suffix(asset.suffix + '.control-saved')
        assert not saved.exists()
        before = snapshot(installed)
        asset.rename(saved)
        try:
            prelaunch('missing-' + name)
            asset.symlink_to(saved.name)
            assert asset.is_symlink() and asset.resolve() == saved
            prelaunch('aliased-' + name)
        finally:
            if asset.is_symlink():
                asset.unlink()
            saved.rename(asset)
        original = asset.read_bytes()
        try:
            asset.write_bytes(b'not a valid payload or manifest')
            prelaunch('corrupt-' + name)
        finally:
            asset.write_bytes(original)
        assert snapshot(installed) == before, 'Prelaunch asset was not restored'
    recovered = run([str(shim), '--help'], cwd, environment)
    assert recovered.stderr == b'' and recovered.stdout.startswith(b'archway [--root ROOT]')
    cases.append({'case': 'restored-payload-help', 'exit': 0})
    return cases


def exercise_corpus(shim, root, cwd, installed, environment, run):
    """Location never silently excludes explicitly selected installed sources."""
    if not installed.is_relative_to(root):
        return {'applicable': False, 'reason': 'installation-outside-inspected-root', 'cases': []}
    import json
    selected = (installed / 'assets/typescript/helper.cjs').relative_to(root).as_posix()
    policy = root / 'architecture.yaml'
    original = policy.read_bytes()
    text = original.decode('utf-8')
    assert 'scope: [src/]' in text and 'exclude: []' in text
    expanded = text.replace('scope: [src/]', 'scope: [src/, ' + json.dumps(selected) + ']')
    cases = []
    try:
        for excluded, code, status in [(False, 2, 'incomplete'), (True, 0, 'ok')]:
            policy.write_text(expanded.replace('exclude: []', 'exclude: [' + json.dumps(selected) + ']')
                              if excluded else expanded, encoding='utf-8')
            before = snapshot(root), snapshot(cwd), snapshot(installed)
            result = run([str(shim), '--root', str(root), 'check'], cwd, environment,
                         expected_exit=code)
            value = assert_result(result, code, status)
            payload = value['payload']
            assert payload['analysis_complete'] is excluded
            paths = [file['path'] for file in payload['coverage']['files']]
            assert (selected in paths) is not excluded
            assert payload['observed']['files'] == (2 if excluded else 3)
            assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
            cases.append({'case': ('excluded' if excluded else 'selected') + '-installed-corpus',
                          'exit': code, 'selected_present': not excluded,
                          'observed_files': payload['observed']['files']})
    finally:
        policy.write_bytes(original)
    assert policy.read_bytes() == original
    return {'applicable': True, 'selected_path': selected, 'cases': cases}
