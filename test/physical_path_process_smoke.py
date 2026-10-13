"""Bounded native malformed-name probes; public CLI JSON is the acceptance seam."""
import errno
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

from jsonschema import Draft202012Validator
from raw_path_fixture import malformed_path

repository = Path(__file__).resolve().parents[1]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
executable, sdk, node = [Path(value).resolve() for value in sys.argv[1:4]]
count = 0


def assert_apfs_rejects_creation(path, *, directory=False):
    # APFS rejects malformed UTF-8 entry names; raw symlink payloads still apply.
    parent = os.path.dirname(path)
    before = set(os.listdir(parent))
    try:
        if directory:
            os.mkdir(path)
        else:
            with open(path, 'wb'):
                pass
    except OSError as error:
        assert error.errno == errno.EILSEQ, error
    else:
        raise AssertionError('APFS accepted a malformed UTF-8 entry name')
    assert set(os.listdir(parent)) == before


with tempfile.TemporaryDirectory(prefix='archway-physical-process-') as temporary:
    base = Path(temporary).resolve()
    root = base / 'project'
    root.mkdir()
    (root / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    def invoke(selected, expected, command='validate', binary=None):
        global count
        result = subprocess.run([str(binary or executable), '--root', os.fsdecode(selected), command], capture_output=True, timeout=10, env={**os.environ, 'PATH':str(sdk / 'bin') + os.pathsep + str(node.parent)})
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'', result.stderr
        assert result.stdout.count(b'\n') == 1, result.stdout
        value = json.loads(result.stdout)
        schema.validate(value)
        assert value['exit_code'] == expected
        count += 1
        return value

    assert invoke(root, 0)['status'] == 'ok'
    long_alias = base / 'long-root'
    # Relative reparse targets require native separators on Windows. Keep all
    # 200 dot components: Path/normalization would erase the long raw payload.
    long_target = ('.' + os.sep) * 200 + 'project'
    long_alias.symlink_to(long_target, target_is_directory=True)
    assert os.readlink(long_alias) == long_target
    assert len(os.fsencode(os.readlink(long_alias))) == 407
    assert long_alias.is_symlink() and long_alias.is_dir()
    assert long_alias.resolve(strict=True) == root
    assert (long_alias / 'architecture.yaml').read_bytes() == (root / 'architecture.yaml').read_bytes()
    print('LONG_ALIAS_FIXTURE_READY raw_target_bytes=407 dot_components=200', flush=True)
    assert invoke(long_alias, 0)['resolved_root'] == str(root)
    cycle = base / 'cycle'
    cycle.symlink_to('cycle', target_is_directory=True)
    assert invoke(cycle, 2)['status'] == 'error'
    for index in range(41):
        (base / f'hop{index}').symlink_to(f'hop{index + 1}' if index < 40 else 'project', target_is_directory=True)
    assert invoke(base / 'hop0', 2)['status'] == 'error'
    raw_directory = malformed_path(base, 'raw')
    if sys.platform == 'darwin':
        assert_apfs_rejects_creation(raw_directory, directory=True)
    else:
        os.mkdir(raw_directory)
    alias = base / 'invalid-root'
    os.symlink(raw_directory, alias, target_is_directory=True)
    assert invoke(alias, 2)['status'] == 'error'
    if sys.platform != 'darwin':
        os.rmdir(raw_directory)

    names = base / 'raw-names'
    names.mkdir()
    (names / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: [./]\nexclude: []\nnodes: []\n')
    raw_name = malformed_path(names, 'bad') + ('.ts' if os.name == 'nt' else b'.ts')
    if sys.platform == 'darwin':
        assert_apfs_rejects_creation(raw_name)
        (names / 'bad�.ts').write_text('export {};')
    else:
        with open(raw_name, 'wb') as stream:
            stream.write(b'export {};')
        for collision in [False, True]:
            if collision:
                (names / 'bad�.ts').write_text('export {};')
            value = invoke(names, 2, 'check')
            assert any(d['code'] == 'CORPUS_ENUMERATION_FAILED' for d in value['payload']['unknowns'])
        os.unlink(raw_name)
    value = invoke(names, 2, 'check')
    assert value['payload']['observed']['files'] == 1
    assert not any(d['code'] == 'CORPUS_ENUMERATION_FAILED' for d in value['payload']['unknowns'])

    replacement = base / 'valid�'
    replacement.mkdir()
    shutil.copy2(root / 'architecture.yaml', replacement / 'architecture.yaml')
    alias.unlink()
    alias.symlink_to(replacement, target_is_directory=True)
    assert invoke(alias, 0)['resolved_root'] == str(replacement)
    isolated = base / 'no-bridge'
    isolated = isolated / 'bin' / executable.parent.name
    isolated.mkdir(parents=True)
    shutil.copy2(executable, isolated / executable.name)
    assert invoke(root, 0, binary=isolated / executable.name)['status'] == 'ok'
    assert invoke(alias, 2, binary=isolated / executable.name)['status'] == 'error'

    for language in ['dart', 'typescript']:
        project = base / language
        (project / 'src').mkdir(parents=True)
        dart = language == 'dart'
        extension = 'dart' if dart else 'ts'
        (project / f'src/main.{extension}').write_text('class Main {}' if dart else 'export {};')
        config = 'analysis_options.yaml' if dart else 'compiler.json'
        config_bytes = b'{}' if dart else b'{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}'
        raw_target = malformed_path(base, 'config-' + language)
        if sys.platform == 'darwin':
            assert_apfs_rejects_creation(raw_target)
        else:
            with open(raw_target, 'wb') as stream:
                stream.write(config_bytes)
        os.symlink(raw_target, project / config)
        if dart:
            (project / '.dart_tool').mkdir()
            (project / '.dart_tool/package_config.json').write_text(json.dumps({'configVersion':2, 'packages':[
                {'name':'fixture','rootUri':'../','packageUri':'src/','languageVersion':'3.13'}]}))
            (project / 'pubspec.yaml').write_text('name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
            project_row = '{id: app, adapter: dart, package_roots: [./]}'
        else:
            (project / 'tsconfig.json').write_text('{"extends":"./compiler.json","include":["src/**/*.ts"]}')
            project_row = '{id: app, adapter: typescript, tsconfig: tsconfig.json}'
        (project / 'architecture.yaml').write_text('version: 1\nprojects: [' + project_row + ']\nscope: [src/]\nexclude: []\nnodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]\n')
        value = invoke(project, 2, 'check')
        assert value['status'] == 'incomplete'
        assert not value['payload']['analysis_complete']
        (project / config).unlink()
        if sys.platform != 'darwin':
            os.unlink(raw_target)
        (project / 'config�').write_bytes(config_bytes)
        (project / config).symlink_to('config�')
        assert invoke(project, 0, 'check')['payload']['analysis_complete']

print(f'{count} bounded real-process physical path checks passed; malformed encoding=' + ('UTF-16' if os.name == 'nt' else 'UTF-8'))
if sys.platform == 'darwin':
    print('APFS rejected malformed entry creation with EILSEQ; malformed symlink targets and valid U+FFFD paths exercised')
