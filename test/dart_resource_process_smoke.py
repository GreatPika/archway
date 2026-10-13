"""Bounded native process checks for unsupported analyzer resource types.

Arguments: compiled CLI, verified Dart SDK. Never open a FIFO in the test runner.
The tested process is killed and reaped by subprocess.run if its deadline fails.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator
from process_fixture_support import dart_executable
from resource_type_fixture import nonregular_resource, remove_nonregular_resource

repository = Path(__file__).resolve().parents[1]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
executable, sdk = [Path(value).resolve() for value in sys.argv[1:3]]
with tempfile.TemporaryDirectory(prefix='archway-resource-types-') as temporary:
    base = Path(temporary).resolve()
    root = base / 'project'
    (root / 'lib').mkdir(parents=True)
    (root / '.dart_tool').mkdir()
    (root / 'lib/main.dart').write_text('class App {}')
    (root / 'pubspec.yaml').write_text('name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
    (root / '.dart_tool/package_config.json').write_text(json.dumps({'configVersion': 2, 'packages': [
        {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'}]}))
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: dart, adapter: dart, package_roots: [./]}]
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [lib/], allows: [], public: []}
''')
    def invoke(runtime, expected):
        result = subprocess.run([str(executable), '--root', str(root), 'check'],
            cwd=base, env={**os.environ, 'PATH': str(runtime / 'bin')},
            capture_output=True, timeout=5)
        assert result.returncode == expected, (result.stdout, result.stderr)
        assert result.stderr == b''
        assert result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout)
        schema.validate(value)
        assert value['exit_code'] == expected
        return value

    assert invoke(sdk, 0)['payload']['analysis_complete']
    damaged = base / 'damaged SDK'
    (damaged / 'bin').mkdir(parents=True)
    shutil.copy2(dart_executable(sdk), dart_executable(damaged))
    nonregular_resource(damaged / 'version')
    value = invoke(damaged, 2)
    assert value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE'
    remove_nonregular_resource(damaged / 'version')
    shutil.copy2(sdk / 'version', damaged / 'version')
    (damaged / 'lib').mkdir()
    nonregular_resource(damaged / 'lib/libraries.json')
    assert invoke(damaged, 2)['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE'
    nonregular_resource(root / 'analysis_options.yaml')
    assert not invoke(sdk, 2)['payload']['analysis_complete']
    remove_nonregular_resource(root / 'analysis_options.yaml')
    assert invoke(sdk, 0)['payload']['analysis_complete']
    actual_options = root / 'options.actual.yaml'
    actual_options.write_text('analyzer:\n  language:\n    strict-casts: true\n')
    (root / 'analysis_options.yaml').symlink_to(actual_options)
    value = invoke(sdk, 0)
    assert {'observed_file_uri': (root / 'analysis_options.yaml').as_uri(),
            'canonical_file_uri': actual_options.as_uri()} in value['payload']['input_identity']['aliases']

print('6 bounded real-process resource-type checks passed; mechanism=' +
      ('nonregular directories (POSIX filesystem FIFO inapplicable)' if os.name == 'nt' else 'POSIX FIFO'))
