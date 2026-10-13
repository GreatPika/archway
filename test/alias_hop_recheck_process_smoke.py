"""Public CLI rechecks hop-only evidence after an earlier route fails."""
import base64
import json
import os
from pathlib import Path
from installation_staging import stage_installation
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repo = Path(__file__).resolve().parents[1]
executable, node = (Path(arg).resolve() for arg in sys.argv[1:3])
schema = Draft202012Validator(json.loads(
    (repo / 'contracts/json/public-result.schema.json').read_text()))
with tempfile.TemporaryDirectory(prefix='archway-independent-hop-') as temporary:
    base = Path(temporary).resolve()
    install, root = base / 'install', base / 'root'
    install.mkdir()
    binary = stage_installation(executable, install)
    (root / 'src').mkdir(parents=True)
    (root / 'empty').mkdir()
    (root / 'other').mkdir()
    (root / 'second').symlink_to('empty', target_is_directory=True)
    first_target = '..' + os.sep + 'second'
    (root / 'src/first').symlink_to(first_target, target_is_directory=True)
    assert os.readlink(root / 'src/first') == first_target
    assert (root / 'src/first').is_dir(), 'Directory-hop fixture is not traversable'
    (root / 'src/main.ts').write_text('export {};')
    (root / 'tsconfig.json').write_text(json.dumps({
        'extends': './src/first/missing.json', 'include': ['src/main.ts']}))
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: [src/first/]
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
''')
    helper = install / 'assets/typescript/helper.cjs'
    request = {'protocol_version': 2, 'request_id': 'check:web',
               'project_id': 'web', 'root_uri': root.as_uri(),
               'config_path': 'tsconfig.json', 'expected_files': ['src/main.ts']}
    captured = subprocess.run(
        [str(node), str(helper)], input=json.dumps(request), text=True,
        capture_output=True, check=True, timeout=30)
    response = json.loads(captured.stdout)
    # Isolate genuine absent-route evidence from redundant directory probes.
    standalone = {(root / name).as_uri() for name in ('second', 'src/first')}
    response['inputs'] = [item for item in response['inputs']
                          if item['observed_uri'] not in standalone]
    assert any(item['kind'] == 'absent' and len(item['symlink_hops']) == 2
               for item in response['inputs'])
    encoded = base64.b64encode(json.dumps(response).encode()).decode()
    first, second = (json.dumps(str(root / name))
                     for name in ('src/first', 'second'))
    helper.write_text(f'''let input = '';
process.stdin.on('data', bytes => input += bytes);
process.stdin.on('end', () => {{
  const fs = require('fs');
  fs.unlinkSync({first}); fs.symlinkSync('first', {first}, 'dir');
  fs.unlinkSync({second}); fs.symlinkSync('other', {second}, 'dir');
  process.stdout.write(Buffer.from('{encoded}', 'base64'));
}});
''')
    result = subprocess.run(
        [str(binary), '--root', str(root), 'check'],
        env={**os.environ, 'PATH': str(node.parent)}, text=True,
        capture_output=True, timeout=30)
    assert result.returncode == 2 and result.stderr == ''
    assert result.stdout.count('\n') == 1
    value = json.loads(result.stdout)
    schema.validate(value)
    payload = value['payload']
    assert any(error['code'] == 'INPUT_RECHECK_FAILED'
               for error in payload['tool_errors'])
    assert {'kind': 'repository', 'path': 'src/first/missing.json'} in \
        payload['input_identity']['changed_inputs'], payload['input_identity']
print('1 bounded independent hop-only evidence recheck passed')
