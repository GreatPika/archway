"""Real prepared Flutter AOT checks. Args: AOT executable, Flutter SDK, fixture.

Fixture preparation is separate and may fetch dependencies. This script never
runs pub, Flutter, project code or builds; SDK copies use local hardlinks only.
Linux syscall observation is evidence, not clean-platform certification.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator
from process_fixture_support import dart_executable

repo = Path(__file__).resolve().parents[1]
executable, flutter, fixture = (Path(v).resolve() for v in sys.argv[1:4])
schema = Draft202012Validator(json.loads((repo / 'contracts/json/public-result.schema.json').read_text()))
count = 0
with tempfile.TemporaryDirectory(prefix='archway-flutter-process-', dir=flutter.parent) as temp:
    base = Path(temp).resolve()
    sdk = base / 'Flutter café SDK'
    shutil.copytree(flutter, sdk, copy_function=os.link, symlinks=True,
                    ignore=shutil.ignore_patterns('.git'))
    marker = base / 'launcher-executed'
    # Windows's documented route selects the prepared embedded SDK directly.
    # Poison the actual .bat launchers too, rather than inventing bin/dart.exe.
    for launcher in (['dart.bat', 'flutter.bat'] if os.name == 'nt' else ['dart', 'flutter']):
        path = sdk / 'bin' / launcher
        path.unlink()  # Never write through a hardlink into the installed SDK.
        if os.name == 'nt':
            path.write_text(f'@echo off\r\necho invoked > "{marker}"\r\nexit /b 99\r\n')
        else:
            path.write_text(f'#!/bin/sh\necho invoked > "{marker}"\nexit 99\n')
            path.chmod(0o755)
    runtime_bin = sdk / ('bin/cache/dart-sdk/bin' if os.name == 'nt' else 'bin')
    root = base / 'prepared app'
    (root / 'lib/app').mkdir(parents=True)
    (root / 'lib/core').mkdir()
    (root / '.dart_tool').mkdir()
    for name in ['pubspec.yaml', 'pubspec.lock']:
        shutil.copy2(fixture / name, root / name)
    config = json.loads((fixture / '.dart_tool/package_config.json').read_text())
    for entry in config['packages']:
        if entry['rootUri'].startswith(flutter.as_uri()):
            entry['rootUri'] = entry['rootUri'].replace(flutter.as_uri(), sdk.as_uri(), 1)
    config['flutterRoot'] = sdk.as_uri()
    (root / '.dart_tool/package_config.json').write_text(json.dumps(config))
    (root / 'architecture.yaml').write_text('''version: 1
projects:
  - {id: app, adapter: dart, package_roots: [./]}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''')
    (root / 'lib/app/main.dart').write_text("import 'package:flutter/foundation.dart';\nimport 'package:flutter_test/flutter_test.dart';\nimport 'dart:ui';\nimport '../core/value.g.dart';\npart 'part.g.dart';\n")
    (root / 'lib/app/part.g.dart').write_text("part of 'main.dart'; class Part {}\n")
    (root / 'lib/core/value.g.dart').write_text('class Generated {}\n')

    def snapshot():
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file()}

    def invoke(expected, trace=False):
        global count
        before = snapshot()
        command = [str(executable), '--root', str(root), 'check']
        trace_file = base / 'syscalls.log'
        if trace:
            command = ['/usr/bin/strace', '-f', '-qq', '-e', 'trace=process,network',
                       '-o', str(trace_file), *command]
        result = subprocess.run(command, cwd=base, env={**os.environ, 'PATH': str(runtime_bin)},
                                capture_output=True, timeout=60)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'', result.stderr
        assert result.stdout.count(b'\n') == 1 and result.stdout.endswith(b'\n')
        value = json.loads(result.stdout)
        schema.validate(value)
        assert value['exit_code'] == expected
        assert value['payload']['input_identity']['rechecked']
        assert snapshot() == before, 'check mutated the prepared project'
        assert not marker.exists(), 'check ran a Flutter launcher'
        if trace:
            calls = trace_file.read_text()
            launches = [line for line in calls.splitlines() if 'execve(' in line]
            assert len(launches) == 2, launches
            assert str(executable) in launches[0], launches
            assert str(dart_executable(sdk / 'bin/cache/dart-sdk')) in launches[1], launches
            assert '"--suppress-analytics", "--version"' in launches[1], launches
            assert 'connect(' not in calls, calls
        count += 1
        return value

    value = invoke(1, trace=os.environ.get('ARCHWAY_SYSCALL_TRACE') == '1')
    assert value['payload']['analysis_complete']
    assert value['payload']['observed'] == {'files': 3, 'analyzed_files': 3, 'edges': 6}
    edges = value['payload']['facts']['edges']
    assert sum(e['resolution']['kind'] == 'builtin' for e in edges) == 3
    assert [v['code'] for v in value['payload']['violations']] == ['DEPENDENCY_NOT_ALLOWED']
    manifest = sdk / 'bin/cache/flutter.version.json'
    inputs = value['payload']['input_identity']['inputs']
    manifest_input = next(i for i in inputs if i['location'].get('canonical_file_uri') == manifest.as_uri())
    assert manifest_input['hash'] == 'sha256:' + hashlib.sha256(manifest.read_bytes()).hexdigest()

    embedder = sdk / 'bin/cache/pkg/sky_engine/lib/_embedder.yaml'
    embedder_bytes = embedder.read_bytes()
    # The selected mapping is a path, not an identity string. Equivalent dot
    # segments must agree with the analyzer's normalized filesystem target.
    assert b'"ui/ui.dart"' in embedder_bytes
    embedder.unlink()  # Never mutate the installed SDK through a hardlink.
    embedder.write_bytes(embedder_bytes.replace(b'"ui/ui.dart"', b'"ui/../ui/ui.dart"'))
    value = invoke(1)
    ui = next(e for e in value['payload']['facts']['edges'] if e['specifier'] == 'dart:ui')
    assert ui['resolution'] == {'kind': 'builtin', 'identity': 'dart:ui'}
    assert value['payload']['analysis_complete']

    # Missing prepared cache cannot be repaired or silently replaced with the
    # ordinary Dart SDK's incomplete Flutter library universe.
    embedder.unlink()
    value = invoke(2)
    assert not value['payload']['analysis_complete']
    assert not embedder.exists()
    assert any(e['code'] == 'DART_ANALYSIS_FAILED' for e in value['payload']['tool_errors'])
    assert any(i['presence'] == 'absent' and i['location'].get('canonical_file_uri') == embedder.as_uri()
               for i in value['payload']['input_identity']['inputs'])

    # With the context mapping available, an absent SDK source is a reference
    # failure and independent local violations remain observable.
    embedder.write_bytes(embedder_bytes)
    ui_source = sdk / 'bin/cache/pkg/sky_engine/lib/ui/ui.dart'
    ui_source.unlink()
    value = invoke(2)
    ui = next(e for e in value['payload']['facts']['edges'] if e['specifier'] == 'dart:ui')
    assert ui['resolution'] == {'kind': 'unresolved'}
    assert not ui_source.exists()
    assert [v['code'] for v in value['payload']['violations']] == ['DEPENDENCY_NOT_ALLOWED']

    # SDK metadata must still pass the stable/embedded-version predicate.
    metadata = json.loads(manifest.read_text())
    metadata['channel'] = 'beta'
    manifest.unlink()
    manifest.write_text(json.dumps(metadata))
    value = invoke(2)
    assert value['tool_versions']['dart_sdk'] is None
    assert any(e['code'] == 'DART_SDK_UNAVAILABLE' for e in value['payload']['tool_errors'])

print(f'{count} real Flutter AOT checks passed; no launcher execution or project writes; syscall tracing=' + str(os.environ.get('ARCHWAY_SYSCALL_TRACE') == '1'))
