"""Real relocated AOT Dart/mixed checks; not clean-platform certification.

Arguments: compiled CLI, pinned Dart SDK directory, pinned Node executable.
No package installation, generated project code, or network is required.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
from installation_staging import stage_installation
from process_fixture_support import dart_executable, compile_runtime_tripwire
import subprocess
import tempfile

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('executable', type=Path)
parser.add_argument('sdk', type=Path)
parser.add_argument('node', type=Path)
parser.add_argument('--existing-installation', action='store_true',
                    help='Use the supplied intact relocated assembly without copying it')
args = parser.parse_args()
executable, sdk, node = (path.resolve() for path in
                         (args.executable, args.sdk, args.node))
expected_host = {('Darwin', 'arm64'): ('darwin', 'arm64'),
                 ('Darwin', 'x86_64'): ('darwin', 'x64'),
                 ('Windows', 'AMD64'): ('win32', 'x64'),
                 ('Windows', 'x86_64'): ('win32', 'x64'),
                 ('Linux', 'x86_64'): ('linux', 'x64')}[
                     (platform.system(), platform.machine())]
identity = subprocess.run([str(node), '-p',
    'JSON.stringify([process.version, process.platform, process.arch])'],
    capture_output=True, text=True, check=True, timeout=15)
assert json.loads(identity.stdout) == ['v24.21.0', *expected_host], identity.stdout
print(f'Pinned external Node: {identity.stdout.strip()}', flush=True)
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
count = 0
with tempfile.TemporaryDirectory(prefix='archway-dart-process-') as temporary:
    base = Path(temporary).resolve()
    install = base / 'installation café'
    install.mkdir()
    binary = executable if args.existing_installation else stage_installation(executable, install)
    root = base / 'prepared project'
    (root / 'lib/app').mkdir(parents=True)
    (root / 'lib/core').mkdir(parents=True)
    (root / '.dart_tool').mkdir()
    (root / 'lib/app/main.dart').write_text("import '../core/private.dart';\n")
    (root / 'lib/core/private.dart').write_text('class Thing {}\n')
    (root / 'lib/app/main.ts').write_text("import '../core/private';\n")
    (root / 'lib/core/private.ts').write_text('export const thing = 1;\n')
    (root / 'pubspec.yaml').write_text('name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
    (root / '.dart_tool/package_config.json').write_text(json.dumps({'configVersion': 2, 'packages': [
        {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'}]}))
    (root / 'tsconfig.json').write_text('{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["lib/**/*.ts"]}')
    (root / 'architecture.yaml').write_text('''version: 1
projects:
  - {id: dart, adapter: dart, package_roots: [./]}
  - {id: web, adapter: typescript, tsconfig: tsconfig.json}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''')
    def invoke(expected, path):
        global count
        command = [str(binary), '--root', str(root), 'check']
        result = subprocess.run(command,
            cwd=base, env={**os.environ, 'PATH': path}, capture_output=True, timeout=45)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'', result.stderr
        assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout.decode('utf-8'))
        schema.validate(value)
        assert value['exit_code'] == expected
        assert value['payload']['input_identity']['rechecked']
        count += 1
        return value

    # Diagnose the pinned compiler's real case-sensitivity probe without changing
    # its input evidence or the mixed-check acceptance assertions below.
    compiler = binary.parents[2] / 'assets/typescript/vendor/typescript/lib/typescript.js'
    original_path = str(compiler)
    # TypeScript 5.9.3 swapCase(__filename) uses JavaScript /\w/g (ASCII).
    swapped_path = ''.join(char.swapcase() if char.isascii() and
                           (char.isalnum() or char == '_') else char
                           for char in original_path)
    node_diagnostic = """
const fs = require('node:fs');
for (const path of process.argv.slice(1)) {
  const row = {path};
  for (const [name, operation] of [['js', fs.realpathSync], ['native', fs.realpathSync.native]]) {
    try { row[name] = operation(path); }
    catch (error) { row[name] = {code: error.code, message: error.message}; }
  }
  console.log(JSON.stringify(row));
}
"""
    print('Compiler case-probe Node JS/native realpath diagnostic:', flush=True)
    subprocess.run([str(node), '-e', node_diagnostic, original_path, swapped_path],
                   check=True, timeout=15)
    dart_diagnostic = base / 'canonical-diagnostic.dart'
    dart_diagnostic.write_text("""import 'dart:convert';
import 'dart:io';
void main(List<String> paths) {
  for (final path in paths) {
    final row = <String, Object?>{'path': path};
    try { row['dart'] = File(path).resolveSymbolicLinksSync(); }
    catch (error) { row['dart'] = error.toString(); }
    print(jsonEncode(row));
  }
}
""")
    print('Compiler case-probe Dart resolveSymbolicLinks diagnostic:', flush=True)
    subprocess.run([str(dart_executable(sdk)), str(dart_diagnostic), original_path, swapped_path],
                   cwd=base, check=True, timeout=30)

    value = invoke(1, os.pathsep.join([str(sdk / 'bin'), str(node.parent)]))
    assert value['status'] == 'negative'
    assert value['payload']['analysis_complete']
    assert value['payload']['observed'] == {'files': 4, 'analyzed_files': 4, 'edges': 2}
    assert {e['project_id']: (e['resolution']['kind'], e['resolution']['path'])
            for e in value['payload']['facts']['edges']} == {
                'dart': ('local', 'lib/core/private.dart'),
                'web': ('local', 'lib/core/private.ts'),
            }
    assert value['tool_versions']['dart_sdk'] == '3.13.3'
    assert value['tool_versions']['typescript'] == '5.9.3'

    # Controlled external runtime boundary, separate from real-runtime checks:
    # a counter verifies one preflight per invocation across overlapping projects.
    runtime = base / 'runtime boundary fixture'
    (runtime / 'bin').mkdir(parents=True)
    shutil.copy2(sdk / 'version', runtime / 'version')
    shutil.copytree(sdk / 'lib', runtime / 'lib', symlinks=True)
    counter = base / 'version queries'
    counter.write_text('')
    wrapper = dart_executable(runtime)
    compile_runtime_tripwire(sdk, wrapper, counter, delegate=dart_executable(sdk))
    policy = root / 'architecture.yaml'
    original = policy.read_text()
    policy.write_text(original.replace('  - {id: web,', '  - {id: dart_other, adapter: dart, package_roots: [./]}\n  - {id: web,'))
    value = invoke(2, os.pathsep.join([str(runtime / 'bin'), str(node.parent)]))
    assert counter.read_text().splitlines() == ['query'], counter.read_text()
    dart_rows = [r for r in value['payload']['coverage']['files'] if r['path'].endswith('.dart')]
    assert all(r['assignment'] == 'ambiguous' and len(r['candidates']) == 2 for r in dart_rows)
    policy.write_text(original)

    # Wrong SDK metadata is rejected before invoking its executable. This is an
    # external test-only SDK copy, never a mutation of the prepared real SDK.
    (runtime / 'version').write_text('0.0.0\n')
    queries_before = counter.read_bytes()
    value = invoke(2, os.pathsep.join([str(runtime / 'bin'), str(node.parent)]))
    assert value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE'
    assert counter.read_bytes() == queries_before

    value = invoke(2, str(node.parent))
    assert value['status'] == 'incomplete'
    assert [e['project_id'] for e in value['payload']['facts']['edges']] == ['web']
    assert value['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
    assert value['tool_versions']['dart_sdk'] is None
    assert value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE'

    value = invoke(2, str(sdk / 'bin'))
    assert [e['project_id'] for e in value['payload']['facts']['edges']] == ['dart']
    assert value['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
    assert value['payload']['tool_errors'][0]['code'] == 'NODE_UNAVAILABLE'

    # A repo-local runtime is not executed, including through an external alias.
    marker = root / 'executed-project-code'
    wrapper = root / dart_executable(sdk).name
    compile_runtime_tripwire(sdk, wrapper, marker)
    aliases = base / 'aliases'
    aliases.mkdir()
    (aliases / wrapper.name).symlink_to(wrapper)
    invoke(2, os.pathsep.join([str(aliases), str(root), str(node.parent)]))
    assert not marker.exists()

    # Unsupported policy spelling remains physical input evidence, never a Plan
    # operand; the incomplete public JSON must still satisfy its schema.
    (root / 'lib/ignored').mkdir()
    (root / 'lib/ignored/bad[1].dart').write_text('class Odd {}')
    (root / 'lib/app/main.dart').write_text("import '../ignored/bad[1].dart';")
    policy.write_text(original.replace('exclude: []', 'exclude: [lib/ignored/]'))
    value = invoke(2, os.pathsep.join([str(sdk / 'bin'), str(node.parent)]))
    edge = next(e for e in value['payload']['facts']['edges'] if e['project_id'] == 'dart')
    assert edge['resolution'] == {'kind': 'unresolved'}
    assert any(i['location'].get('path') == 'lib/ignored/bad[1].dart' for i in value['payload']['input_identity']['inputs'])

print(f'{count} real Dart/mixed AOT process checks passed')
