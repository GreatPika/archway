"""CLI regressions for realpath identity, persistent route changes and trace gaps."""
import json
import hashlib
import os
from pathlib import Path
from installation_staging import stage_installation
import subprocess
import sys
import tempfile
from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable, node = [Path(value).resolve() for value in sys.argv[1:3]]
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
with tempfile.TemporaryDirectory(prefix='archway-trace-gap-') as temporary:
    base = Path(temporary).resolve()
    install = base / 'installation'
    install.mkdir()
    binary = stage_installation(executable, install)
    root = base / 'project'
    (root / 'src/app').mkdir(parents=True)
    (root / 'src/core').mkdir()
    (root / 'src/app/main.ts').write_text("import '../core/private';")
    (root / 'src/core/private.ts').write_text('export {};')
    (root / 'tsconfig.json').write_text('{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}')
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''')
    # Instrument our isolated trusted helper while retaining its production
    # tracer, compiler and the complete CLI.
    helper = install / 'assets/typescript/helper.cjs'
    source = helper.read_text()
    marker = 'const rootInput = evidence.observe(root);'
    assert source.count(marker) == 1
    # Exercise both Node realpath APIs through the production observer, including
    # the compiler's genuine ASCII case probe on a case-insensitive filesystem.
    compiler = str(helper.parent / 'vendor/typescript/lib/typescript.js')
    swapped = ''.join(c.swapcase() if c.isascii() and (c.isalnum() or c == '_') else c
                      for c in compiler)
    def check(expected):
        result = subprocess.run([str(binary), '--root', str(root), 'check'],
            env={**os.environ, 'PATH': str(node.parent)}, capture_output=True, timeout=30)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'' and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout)
        schema.validate(value)
        return value['payload']

    calls = "for (const p of " + json.dumps([compiler, swapped]) + ") { if (fs.existsSync(p)) { fs.realpathSync(p); fs.realpathSync.native(p); } }"
    helper.write_text(source.replace('const rootInput = evidence.observe(root);',
                                    calls + "\n      const rootInput = evidence.observe(root);"))
    assert check(1)['analysis_complete']

    # Mutate an ordinary external file/ancestor only after the raw route was
    # traced, while native realpath is entering. Bytes remain unchanged.
    real_helper = helper.with_name('real-helper.cjs')
    probe = base / 'probe'
    probe.mkdir()
    leaf = probe / 'same.json'
    leaf.write_text('{}')
    real_helper.write_text(source.replace('const rootInput = evidence.observe(root);',
        "fs.statSync(" + json.dumps(str(leaf)) + ");\n      const rootInput = evidence.observe(root);"))
    for move, target in [(leaf, base / 'same.json'), (probe, base / 'moved-probe')]:
        link_type = 'dir' if move.is_dir() else 'file'
        helper.write_text("const fs=require('node:fs'), native=fs.realpathSync.native;let first=true;"
            "fs.realpathSync.native=function(file,...args){if(first && String(file)===" + json.dumps(str(leaf)) +
            "){first=false;fs.renameSync(" + json.dumps(str(move)) + "," + json.dumps(str(target)) +
            ");fs.symlinkSync(" + json.dumps(str(target)) + "," + json.dumps(str(move)) +
            "," + json.dumps(link_type) + ");}return native(file,...args);};require('./real-helper.cjs');")
        report = check(2)
        assert move.is_symlink(), 'The persistent-link injection must execute'
        assert any(e['code'] == 'TYPESCRIPT_INPUT_TRACE_FAILED' for e in report['tool_errors']), report
        assert report['facts']['edges'] and report['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
        move.unlink()
        target.rename(move)

    # Retarget an existing intermediate alias through an additional hop while
    # preserving the final pathname and hash. Independent recheck must catch it.
    alias, via = base / 'through', base / 'via'
    alias.symlink_to(probe, target_is_directory=True)
    via.symlink_to(probe, target_is_directory=True)
    assert alias.is_dir() and via.is_dir(), 'Directory aliases are not traversable'
    observed = str(alias / 'same.json')
    real_helper.write_text(source.replace('const rootInput = evidence.observe(root);',
        "fs.statSync(" + json.dumps(observed) + ");\n      const rootInput = evidence.observe(root);"))
    helper.write_text("const fs=require('node:fs'), native=fs.realpathSync.native;let first=true;"
        "fs.realpathSync.native=function(file,...args){if(first && String(file)===" + json.dumps(observed) +
        "){first=false;fs.unlinkSync(" + json.dumps(str(alias)) + ");fs.symlinkSync(" +
        json.dumps(str(via)) + "," + json.dumps(str(alias)) +
        ",'dir');}return native(file,...args);};require('./real-helper.cjs');")
    report = check(2)
    target = str(alias.readlink())
    if os.name == 'nt' and target.startswith('\\\\?\\'):
        target = target[4:]  # os.readlink returns the Win32 substitute-name prefix.
    assert os.path.normcase(target) == os.path.normcase(str(via)), 'The intermediate-hop injection must execute'
    assert any(e['code'] == 'INPUT_CHANGED' for e in report['unknowns']), report
    assert not report['analysis_complete']

    helper.write_text(source.replace('const rootInput = evidence.observe(root);',
        "try { fs.readFileSync(" + json.dumps(str(base / 'optional.json')) + "); } catch {}\n      const rootInput = evidence.observe(root);"))
    (base / 'exists').write_text('exists')
    (base / 'regular').write_text('regular')
    for target in [b'missing.json', b'missing\xff.json', b'missing/../exists', b'regular/../exists']:
        optional = base / 'optional.json'
        # Preserve malformed native encoding: UTF-16 surrogate on Windows,
        # raw UTF-8 bytes on POSIX. No replacement-character substitution.
        # Keep dot-walk failures distinct from invalid Windows separators.
        native_target = target.decode('utf-8', errors='surrogateescape').replace('/', os.sep) if os.name == 'nt' else target
        os.symlink(native_target, optional)
        assert os.readlink(os.fsencode(optional) if isinstance(native_target, bytes) else optional) == native_target
        # Windows resolves these native dot-segment targets before the file
        # lookup. POSIX requires the missing/regular component to be traversable.
        readable_dot_target = os.name == 'nt' and target in (
            b'missing/../exists', b'regular/../exists')
        if readable_dot_target:
            assert optional.read_bytes() == b'exists'
            assert optional.resolve(strict=True) == base / 'exists'
        else:
            try:
                optional.read_bytes()
            except OSError:
                pass
            else:
                raise AssertionError(('Expected an unreadable alias target', native_target))
        expected_exit = 1 if readable_dot_target else 2
        result = subprocess.run([str(binary), '--root', str(root), 'check'],
            env={**os.environ, 'PATH':str(node.parent)}, capture_output=True, timeout=20)
        assert result.returncode == expected_exit, (native_target, result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'' and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout)
        schema.validate(value)
        report = value['payload']
        if readable_dot_target:
            identity = report['input_identity']
            assert report['analysis_complete'] and not report['tool_errors']
            assert identity['rechecked'] and identity['changed_inputs'] == []
            assert {'kind': 'resolution', 'location': {
                'kind': 'external', 'canonical_file_uri': (base / 'exists').as_uri()},
                'presence': 'present', 'hash': 'sha256:' + hashlib.sha256(b'exists').hexdigest()} in identity['inputs']
            assert {'observed_file_uri': optional.as_uri(),
                    'canonical_file_uri': (base / 'exists').as_uri()} in identity['aliases']
        else:
            assert not report['analysis_complete']
            assert any(error['code'] == 'TYPESCRIPT_INPUT_TRACE_FAILED' for error in report['tool_errors'])
        assert report['facts']['edges']
        assert report['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
        optional.unlink()
print('8 realpath API, persistent-hop and caught-read alias trace-gap checks passed')
