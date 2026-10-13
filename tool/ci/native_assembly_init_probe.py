"""Real maintainer assembly/init and process regressions, not package certification.

Contract: contracts/compatibility/delivery.md, fixed native layout, owned assets,
relocation and runtime independence. Run on native macOS arm64, Linux x64,
or Windows x64 (explicit init-only profile).
Uses the actual assembler and compiler; no platform spoofing or fake payloads.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from aot_init_assertions import assert_aot_init
from installation_artifact import export_installation, source_identity, runtime_version
from windows_assembly_assertions import assert_windows_assembly_guards


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifact-directory', type=Path,
                    help='Export the verified installation to a new artifact directory')
parser.add_argument('--log-directory', type=Path,
                    help='Preserve separate asset, CLI and optional compiler evidence logs')
parser.add_argument('--init-only', action='store_true',
                    help='Check assembly, exact assets, relocation and init only')
parser.add_argument('--dart', type=Path,
                    help='Explicit pinned Dart compiler executable for Windows assembly')
parser.add_argument('--dart-sdk', type=Path,
                    help='Pinned external SDK for optional mixed compiler checks')
parser.add_argument('--node', type=Path,
                    help='Pinned external Node executable for optional compiler checks')
args = parser.parse_args()
if (args.dart_sdk is None) != (args.node is None):
    parser.error('--dart-sdk and --node must be supplied together')
if args.init_only and args.dart_sdk is not None:
    parser.error('--init-only cannot be combined with mixed compiler checks')
if args.dart_sdk is not None:
    args.dart_sdk = args.dart_sdk.resolve(strict=True)
    args.node = args.node.resolve(strict=True)
if args.log_directory:
    args.log_directory = args.log_directory.resolve()
    args.log_directory.mkdir(parents=True, exist_ok=True)

targets = {
    ('Darwin', 'arm64'): ('macos-arm64', 'libarchway_io.dylib'),
    ('Linux', 'x86_64'): ('linux-x64', 'libarchway_io.so'),
    ('Windows', 'AMD64'): ('windows-x64', 'archway_io.dll'),
}
host = (platform.system(), platform.machine())
assert host in targets, f'Prerequisite failure: unsupported native host {host}'
target, bridge_name = targets[host]
if target == 'windows-x64':
    if not args.init_only or args.dart is None:
        parser.error('Windows assembly requires --init-only and --dart')
    args.dart = args.dart.resolve(strict=True)
    assert args.dart.is_file(), 'Windows assembly needs an existing Dart executable.'
elif args.dart is not None:
    parser.error('--dart is only used by the Windows assembler')
repo = Path(__file__).resolve().parents[2]
source_assets = repo / 'assets/typescript'
if args.artifact_directory is not None:
    # Do not resolve the leaf: even a dangling destination alias must be refused.
    args.artifact_directory = args.artifact_directory.absolute()
    if args.artifact_directory.exists() or args.artifact_directory.is_symlink():
        raise FileExistsError(f'Artifact destination already exists: {args.artifact_directory}')
    source_record = source_identity(repo)

    # Unix assemble.sh changes to repo before resolving Dart through PATH.
    build_dart = args.dart or 'dart'
    runtimes = {'build_dart': runtime_version(build_dart, repo)}
    if args.dart_sdk is not None:
        runtimes['analysis_dart'] = runtime_version(args.dart_sdk / 'bin/dart', repo)
        runtimes['analysis_node'] = runtime_version(args.node, repo)

for package, version in [('typescript', '5.9.3'), ('yaml', '2.8.1')]:
    manifest = source_assets / 'vendor' / package / 'package.json'
    assert json.loads(manifest.read_text())['version'] == version
assert (source_assets / 'vendor/typescript/lib/typescript.js').is_file()
assert (source_assets / 'vendor/yaml/dist/index.js').is_file()

with tempfile.TemporaryDirectory(prefix='archway-native-assembly-') as temporary:
    # Canonicalize macOS /var aliases before testing installation relocation.
    base = Path(temporary).resolve()
    output = base / 'assembled café installation'
    assert not output.exists()
    if target == 'windows-x64':
        powershell = shutil.which('pwsh')
        assert powershell, 'Prerequisite failure: native PowerShell is unavailable.'
        assembler = repo / 'tool/assemble_windows.ps1'
        if not assembler.is_file():
            print(f'MISSING_WINDOWS_ASSEMBLER: {assembler}', flush=True)
        # Invoke even when absent: preserve the real PowerShell failure as red.
        command = [powershell, '-NoProfile', '-File', str(assembler),
                   '-Output', str(output), '-Dart', str(args.dart)]
    else:
        command = ['sh', str(repo / 'tool/assemble.sh'), str(output)]
    subprocess.run(command, cwd=base, check=True, timeout=240)
    # Move the entire assembled installation before invoking its genuine CLI.
    bundle = base / 'relocated ü installation'
    output.rename(bundle)
    binary_name = 'archway.exe' if target == 'windows-x64' else 'archway'
    binary = bundle / 'bin' / target / binary_name
    bridge = bundle / 'native' / target / bridge_name
    assert sorted(path.name for path in bundle.iterdir()) == [
        'assets', 'bin', 'native']
    assert list((bundle / 'bin').iterdir()) == [binary.parent]
    assert list(binary.parent.iterdir()) == [binary]
    assert list((bundle / 'native').iterdir()) == [bridge.parent]
    assert list(bridge.parent.iterdir()) == [bridge]
    for artifact in [binary, bridge]:
        assert artifact.is_file() and not artifact.is_symlink()
        print(f'{artifact.relative_to(bundle)} sha256='
              f'{hashlib.sha256(artifact.read_bytes()).hexdigest()}')
    expected_assets = set()
    for pattern in ['*.cjs', '*.json', '*.md']:
        expected_assets.update(source_assets.glob(pattern))
    for directory in ['licenses', 'vendor']:
        expected_assets.update(path for path in (source_assets / directory).rglob('*')
                               if path.is_file())
    staged_assets = bundle / 'assets/typescript'
    assert {path.relative_to(staged_assets) for path in staged_assets.rglob('*')
            if path.is_file()} == {
                path.relative_to(source_assets) for path in expected_assets}
    for source in expected_assets:
        staged = staged_assets / source.relative_to(source_assets)
        assert not staged.is_symlink() and staged.read_bytes() == source.read_bytes()
    print(f'Verified {len(expected_assets)} exact owned asset files.')
    assert_aot_init(binary, base)
    if target == 'windows-x64':
        assert_windows_assembly_guards(repo, powershell, args.dart, base)
    # Reuse this exact relocated assembly before its temporary tree is removed.
    # The asset suite copies it before tampering; CLI uses the intact assembly.
    suites = [] if args.init_only else [
        ('native_asset_process_smoke.py', 'assembly-assets.log'),
        ('cli_process_smoke.py', 'assembly-cli.log'),
    ]
    if args.dart_sdk is not None:
        suites.append(('dart_check_process_smoke.py', 'assembly-compilers.log'))
        suites.append(('alias_trace_gap_process_smoke.py', 'assembly-alias-trace.log'))
    for suite, log_name in suites:
        command = [sys.executable, '-u', str(repo / 'test' / suite), str(binary)]
        if suite == 'dart_check_process_smoke.py':
            command += [str(args.dart_sdk), str(args.node), '--existing-installation']
        elif suite == 'alias_trace_gap_process_smoke.py':
            command += [str(args.node)]
        log = (args.log_directory or base) / log_name
        print(f'Running {suite} against {binary}', flush=True)
        with log.open('w') as evidence:
            try:
                subprocess.run(command, cwd=base, stdout=evidence,
                               stderr=subprocess.STDOUT, check=True, timeout=120)
            finally:
                evidence.flush()
                print(log.read_text(), end='', flush=True)
    if args.artifact_directory is not None:
        if source_identity(repo) != source_record:
            raise ValueError('Tracked source identity changed during assembly checks')
        expected = {binary.relative_to(bundle).as_posix(),
                    bridge.relative_to(bundle).as_posix()}
        expected.update('assets/typescript/' + path.relative_to(source_assets).as_posix()
                        for path in expected_assets)
        provenance = {
            'source': source_record, 'target': target,
            'host': {'system': host[0], 'machine': host[1],
                     'release': platform.release()},
            'checks': {'profile': 'init-only' if args.init_only else 'process',
                       'suites': [suite for suite, _ in suites],
                       'relocated_init': True, 'transported_init': True},
            'runtimes': runtimes,
        }

        def verify_transported(extracted, fresh_base):
            assert_aot_init(extracted / binary.relative_to(bundle), fresh_base)
            if source_identity(repo) != source_record:
                raise ValueError('Tracked source changed during transport checks')

        export_installation(bundle, args.artifact_directory, expected,
                            provenance, verify_transported)
        print(f'Verified installation artifact: {args.artifact_directory}', flush=True)
if args.init_only:
    print(f'Genuine assembled {target} AOT init passed after relocation '
          'with Dart/Node absent from PATH; process regressions were not requested.')
else:
    print(f'Genuine assembled {target} AOT init and process regressions passed after relocation, '
          'with baseline init/asset/CLI checks excluding Dart/Node from PATH.')
if args.dart_sdk is not None:
    print('Mixed compiler checks passed using explicitly supplied pinned external runtimes.')
