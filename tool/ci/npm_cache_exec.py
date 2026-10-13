"""Cache-only npm exec acceptance; every invocation remains behind npm exec."""
import json
import os
from pathlib import Path
import shutil

from npm_probe_budgets import NPM_PREPARATION_TIMEOUT
from npm_installed_acceptance import accept_installation, digest


def exec_arguments(npm, archive, arguments):
    return [str(npm), 'exec', '--ignore-scripts', '--offline', '--yes',
            '--package=' + str(archive), '--', *arguments]


def bind_selection(value, cache, node):
    shim, installed = Path(value['shim']), Path(value['installed'])
    boundary = cache / '_npx'
    assert shim.is_absolute() and shim.is_relative_to(boundary), 'Shim outside requested cache'
    assert shim.resolve().is_relative_to(boundary), 'Shim resolves outside requested cache'
    assert installed.is_relative_to(boundary) and installed.resolve() == installed, 'Package outside requested cache'
    assert shim.parent.name == '.bin' and shim.name in {'archway', 'archway.cmd'}
    assert installed == (shim.parent.parent / 'archway-architecture-cli').resolve(), 'Wrong selected package'
    assert shim.is_file() and installed.is_dir()
    assert Path(value['node']).resolve() == node and value['version'] == 'v24.21.0'
    assert value['dart'] is None, 'Dart unexpectedly available inside npm exec'
    return shim, installed


def payload_control(installed, target, run_help):
    binary = installed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')
    original = digest(binary)
    saved = binary.with_suffix('.cache-control-backup')
    assert not saved.exists()
    binary.rename(saved)
    try:
        failed = run_help(126)
        assert failed.returncode == 126 and failed.stdout == b''
        assert b'archway launcher:' in failed.stderr
    finally:
        saved.rename(binary)
    assert digest(binary) == original, 'Cached payload was not restored exactly'
    recovered = run_help(0)
    assert recovered.returncode == 0 and recovered.stderr == b''
    assert recovered.stdout.startswith(b'archway [--root ROOT]')
    return {'missing_payload_exit': 126, 'restored_payload_sha256': original, 'recovered_help': 0}


LOCATOR = r'''const fs = require('node:fs');
const path = require('node:path');
function find(name) {
  const suffixes = process.platform === 'win32'
    ? (process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').map(s => s.toLowerCase()) : [''];
  for (const directory of process.env.PATH.split(path.delimiter)) {
    for (const suffix of suffixes) {
      const file = path.join(directory, name + suffix);
      try { if (fs.statSync(file).isFile()) { fs.accessSync(file, fs.constants.X_OK); return file; } }
      catch (_) { }
    }
  }
  return null;
}
const shim = find('archway');
if (!shim) throw Error('No archway selected by npm exec PATH');
const installed = fs.realpathSync(path.join(path.dirname(path.dirname(shim)), 'archway-architecture-cli'));
console.log(JSON.stringify({shim, installed, node: process.execPath, version: process.version,
                           dart: find('dart'), path: process.env.PATH}));
'''


def exercise_cache(base, archive, evidence, target, node, npm, project, foreign, environment, checked, command, *, wrong_node=None):
    cache = Path(environment['npm_config_cache'])
    assert not (cache / '_npx').exists(), 'Cache installation must start fresh'
    assert list(foreign.iterdir()) == []
    assert shutil.which('archway', path=environment['PATH']) is None, 'Parent PATH has an Archway fallback'
    environment = {**environment, 'npm_config_prefix': str(base / 'unused global prefix ü'),
                   'npm_config_script_shell': str(Path(os.environ['SystemRoot']) / 'System32/cmd.exe')
                   if os.name == 'nt' else '/bin/sh'}
    locator = base / 'cache locator.cjs'
    locator.write_text(LOCATOR, encoding='utf-8')
    located = checked(exec_arguments(npm, archive, ['node', str(locator)]), foreign, environment, timeout=NPM_PREPARATION_TIMEOUT)
    assert located.stderr == b''
    selection = json.loads(located.stdout.decode('utf-8'))
    shim, installed = bind_selection(selection, cache, node)

    def arguments(values):
        assert values[0] == str(shim), 'Unexpected logical cache command'
        return exec_arguments(npm, archive, ['archway', *values[1:]])

    def invoke(values, cwd, env, timeout=NPM_PREPARATION_TIMEOUT, *, expected_exit=0):
        allowed_paths = {environment['PATH'], str(project.parent / 'missing node runtime')}
        if wrong_node is not None:
            allowed_paths.add(str(wrong_node.parent))
        assert env.get('PATH') in allowed_paths, 'Unexpected cache runtime PATH'
        assert {**env, 'PATH': environment['PATH']} == environment, 'Only controlled runtime PATH may change'
        return checked(arguments(values), cwd, env, timeout=timeout, expected_exit=expected_exit)

    result = accept_installation(shim, project, foreign, installed, installed, evidence,
                                 base / 'cached init café', environment, invoke,
                                 lambda values: command(arguments(values)), target=target, wrong_node=wrong_node, cache_route=True)
    control = payload_control(installed, target,
        lambda expected: invoke([str(shim), '--help'], foreign, environment, expected_exit=expected))
    assert list(foreign.iterdir()) == []
    assert not (project / 'node_modules/archway-architecture-cli').exists()
    return {'phase': 'cached', **result, 'cache_selection': selection,
            'npm_script_shell': environment['npm_config_script_shell'], 'payload_control': control}
