"""Execute the exact final portable archive on its real host; no publication."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_bundles import verify_bundle
from combine_installations import (MAX_FILES, MAX_FILE, MAX_TOTAL, MAX_JSON,
                                   canonical, ordinary, unique_object)
from installation_artifact import _sha256, source_identity
from aot_init_assertions import assert_aot_init
from npm_local_analysis import exercise
from npm_local_install_probe import runtime_environment
from setup_pub_dart import host as require_ci_host
from native_acceptance import run_acceptance, read_fixtures, suite_commands, execute_suite

TARGETS = {'linux-x64': ('Linux', 'x86_64', 'linux', 'x64'),
           'macos-arm64': ('Darwin', 'arm64', 'darwin', 'arm64'),
           'windows-x64': ('Windows', 'amd64', 'win32', 'x64')}


def checked(arguments, cwd, environment, *, expected_exit=0, record=None, timeout=30):
    try:
        result = subprocess.run(arguments, cwd=cwd, env=environment, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        if record is not None:
            record(subprocess.CompletedProcess(arguments, None, error.stdout or b'', error.stderr or b''))
        raise
    if record is not None:
        record(result)
    if result.returncode != expected_exit:
        raise ValueError(f'Native command failed: {arguments}: {result.returncode}: {result.stderr!r}')
    return result


def archive_manifest(archive, windows):
    if windows:
        with zipfile.ZipFile(archive) as stream:
            item = stream.getinfo('manifest.json')
            if item.file_size > MAX_JSON:
                raise ValueError('Manifest exceeds bound')
            data = stream.read(item)
    else:
        with tarfile.open(archive, 'r:gz') as stream:
            item = stream.getmember('manifest.json')
            if item.size > MAX_JSON or not item.isreg():
                raise ValueError('Invalid manifest member')
            data = stream.extractfile(item).read()
    value = json.loads(data, object_pairs_hook=unique_object)
    files = value['files']
    if not isinstance(files, dict) or not 1 <= len(files) < MAX_FILES or 'manifest.json' in files:
        raise ValueError('Invalid native file inventory')
    total = 0
    for name, entry in files.items():
        if (not canonical(name) or set(entry) != {'sha256', 'size', 'mode'}
                or type(entry['size']) is not int or not 0 <= entry['size'] <= MAX_FILE
                or type(entry['mode']) is not int or entry['mode'] not in {0o644, 0o755, 0o666, 0o777}
                or not isinstance(entry['sha256'], str) or len(entry['sha256']) != 64):
            raise ValueError('Invalid native manifest entry')
        total += entry['size']
    if total > MAX_TOTAL:
        raise ValueError('Native expansion exceeds bound')
    expected = {**files, 'manifest.json': {'sha256': hashlib.sha256(data).hexdigest(),
                                         'size': len(data), 'mode': 0o644}}
    verify_bundle(archive, expected, windows)
    return value, expected


def installed_commands(binary, bundle, base, node, target, *, read_only=False, run=checked, record=None):
    foreign = base / 'foreign'
    foreign.mkdir()
    no_runtimes = {**runtime_environment(os.environ, node.parent), 'PATH': str(base / 'no-runtime')}
    help_result = run([str(binary), '--help'], foreign, no_runtimes)
    version_result = run([str(binary), '--version'], foreign, no_runtimes)
    if (not help_result.stdout.startswith(b'archway [--root ROOT]') or help_result.stderr
            or version_result.stdout not in (b'archway 0.1.0\n', b'archway 0.1.0\r\n')
            or version_result.stderr):
        raise ValueError('Unexpected native help/version')
    init_base = base / 'init'
    init_base.mkdir()
    initialized = assert_aot_init(binary, init_base, environment=no_runtimes, label='Native installation')
    if record is not None:
        record(initialized)
    policy_root = init_base / 'empty project café'
    valid = run([str(binary), '--root', str(policy_root), 'validate'], foreign, no_runtimes)
    if json.loads(valid.stdout)['exit_code'] != 0 or valid.stderr:
        raise ValueError('Final native policy validation failed')
    exported = run([str(binary), '--root', str(policy_root), 'export', '--format', 'mermaid'],
                       foreign, no_runtimes)
    if (not exported.stdout.endswith(b'flowchart LR\n')
            or json.loads(exported.stderr)['exit_code'] != 0):
        raise ValueError('Final native Mermaid export failed')
    project = base / 'prepared project'
    project.mkdir()
    analysis = exercise(binary, project, foreign, bundle,
                        runtime_environment(os.environ, node.parent), run,
                        installation_root=bundle, read_only=read_only)
    return {'native_commands': ['help', 'version', 'init', 'validate', 'export'],
            'typescript': analysis}


def probe(args):
    release = args.release_directory.absolute()
    report = args.report.absolute()
    if os.path.lexists(report):
        raise ValueError('Report already exists')
    identity = source_identity(Path.cwd())
    if identity['commit'] != args.expected_commit:
        raise ValueError('Source checkout differs from expected commit')
    system, machine, node_platform, node_arch = TARGETS[args.target]
    if (platform.system(), platform.machine().lower()) != (system, machine):
        raise ValueError('Wrong native host')
    host = require_ci_host(args.target) if args.ci_host else {
        'system': platform.system(), 'machine': platform.machine(),
        'version': platform.version(), 'release': platform.release()}
    node = Path(shutil.which('node') or '').resolve()
    version = subprocess.run([str(node), '-p',
        'JSON.stringify([process.version,process.platform,process.arch])'],
        check=True, capture_output=True, text=True, timeout=15)
    if json.loads(version.stdout) != ['v24.21.0', node_platform, node_arch]:
        raise ValueError('Wrong pinned analysis Node')
    windows = args.target == 'windows-x64'
    filename = 'archway-0.1.0-' + args.target + ('.zip' if windows else '.tar.gz')
    archive = release / filename
    ordinary(archive, MAX_TOTAL)
    ordinary(release / 'SHA256SUMS', MAX_JSON)
    sums = {}
    for line in (release / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ')
        if name in sums or not canonical(name) or '/' in name:
            raise ValueError('Invalid SHA256SUMS inventory')
        sums[name] = digest
    archive_sha = _sha256(archive)
    if sums.get(filename) != archive_sha:
        raise ValueError('SHA256SUMS mismatch')
    manifest, expected = archive_manifest(archive, windows)
    if manifest['source'] != identity or manifest['target'] != args.target:
        raise ValueError('Final native manifest source/target mismatch')
    with tempfile.TemporaryDirectory(prefix='archway release ') as temp:
        base = Path(temp).resolve()
        bundle = base / 'extracted installation'
        if windows:
            environment = {**os.environ, 'ARCHWAY_SMOKE_ARCHIVE': str(archive),
                           'ARCHWAY_SMOKE_OUTPUT': str(bundle)}
            subprocess.run(['pwsh', '-NoProfile', '-Command',
                '$ErrorActionPreference="Stop"; Expand-Archive -LiteralPath '
                '$env:ARCHWAY_SMOKE_ARCHIVE -DestinationPath $env:ARCHWAY_SMOKE_OUTPUT'],
                env=environment, check=True, timeout=60)
        else:
            bundle.mkdir()
            subprocess.run(['tar', '-xzf', str(archive), '-C', str(bundle)], check=True, timeout=60)
        def verify_installation():
            actual = set()
            for path in bundle.rglob('*'):
                if path.is_dir() and not path.is_symlink():
                    continue
                ordinary(path, MAX_FILE)
                name = path.relative_to(bundle).as_posix()
                entry = expected.get(name)
                if entry is None or _sha256(path) != entry['sha256'] or path.stat().st_size != entry['size']:
                    raise ValueError('Extracted bytes differ from native manifest')
                if not windows and stat.S_IMODE(path.stat().st_mode) != entry['mode']:
                    raise ValueError('Extraction changed Unix permissions')
                actual.add(name)
            if actual != expected.keys():
                raise ValueError('Extraction omitted files')
        verify_installation()
        extracted = bundle
        bundle = base / 'relocated café installation'
        extracted.rename(bundle)
        if extracted.exists():
            raise ValueError('Original installation survived relocation')
        verify_installation()
        binary = bundle / 'bin' / args.target / ('archway.exe' if windows else 'archway')
        installed = installed_commands(binary, bundle, base, node, args.target)
        installer = None
        if args.installer_checks:
            if not args.ci_host or args.acceptance_fixtures is None:
                raise ValueError('Installer checks require verified CI host and prepared fixtures')
            def inspect_installed(installed_binary, installed_root):
                project_base = base / 'installer commands'
                project_base.mkdir()
                processes = []
                def record(process):
                    directory = report.parent / 'installer'
                    prefix = 'installed-' + str(len(processes))
                    receipt = {'arguments': list(map(str, process.args)), 'exit': process.returncode}
                    for name, data in [('stdout', process.stdout), ('stderr', process.stderr)]:
                        path = directory / (prefix + '.' + name + '.log')
                        path.write_bytes(data)
                        receipt[name] = path.name
                        receipt[name + '_sha256'] = _sha256(path)
                    processes.append(receipt)
                def run(*arguments, **keywords):
                    return checked(*arguments, **keywords, record=record)
                result = installed_commands(installed_binary, installed_root, project_base, node,
                                            args.target, read_only=True, run=run, record=record)
                result.update(binary=str(installed_binary), installation_root=str(installed_root),
                              manifest_sha256=_sha256(installed_root / 'manifest.json'),
                              processes=processes)
                fixtures = json.loads(args.acceptance_fixtures.read_text())
                wrong = Path(fixtures['wrong_node'])
                cases = []
                for name, runtime, expected in [('missing-node', None, 'NODE_UNAVAILABLE'),
                                                ('wrong-node', wrong, 'NODE_UNAVAILABLE')]:
                    environment = runtime_environment(os.environ, node.parent)
                    environment['PATH'] = str(runtime.parent if runtime is not None else base / 'no-runtime')
                    process = run([str(installed_binary), '--root',
                                       str(project_base / 'prepared project'), 'check'],
                                      project_base / 'foreign', environment, expected_exit=2)
                    value = json.loads(process.stdout)
                    errors = [e['code'] for e in value['payload']['tool_errors']]
                    if errors != [expected] or process.stderr:
                        raise ValueError('Installed external-runtime failure differs')
                    cases.append({'case': name, 'exit': process.returncode, 'errors': errors})
                result['runtime_controls'] = cases
                fixture_paths, _ = read_fixtures(args.acceptance_fixtures)
                suite_directory = report.parent / 'installer' / 'suites'
                suite_directory.mkdir()
                environment = {**os.environ, **fixture_paths['environment']}
                environment['PATH'] = os.pathsep.join([str(fixture_paths['dart_sdk'] / 'bin'),
                                                       str(node.parent), environment.get('PATH', '')])
                selected = [(name, command) for name, command in suite_commands(
                    Path.cwd(), installed_binary, node, fixture_paths, suite_directory)
                    if name in ('plan_query', 'dart_check')]
                result['suites'] = [execute_suite(name, command, Path.cwd(), environment, suite_directory)
                                    for name, command in selected]
                return result
            if args.target == 'linux-x64':
                from native_linux_installer_probe import run_linux
                installer = run_linux(bundle, report.parent / 'installer', args.expected_commit,
                                      inspect_installed, privilege=['sudo', '-n'])
            elif args.target == 'macos-arm64':
                from native_macos_installer_probe import run_macos
                installer = run_macos(bundle, report.parent / 'installer', inspect_installed)
            else:
                from native_windows_installer_probe import run_windows
                installer = run_windows(bundle, report.parent / 'installer', inspect_installed)
            installer.update(scope='Native build and command-line lifecycle; GUI/trust/fresh desktop terminal pending',
                             bundle_manifest_sha256=_sha256(bundle / 'manifest.json'))
        acceptance = None
        if args.acceptance_fixtures:
            if args.ci_host and source_identity(Path(__file__).resolve().parents[2]) != identity:
                raise ValueError('Acceptance test checkout differs from archive source')
            acceptance = run_acceptance(Path(__file__).resolve().parents[2], binary, node,
                args.acceptance_fixtures, report.parent / 'acceptance', verify_installation)
        verify_installation()
        if _sha256(archive) != archive_sha:
            raise ValueError('Final archive changed during host checks')
    if source_identity(Path.cwd()) != identity:
        raise ValueError('Source changed during host checks')
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open('x', encoding='utf-8') as stream:
        json.dump({'scope': 'Final native archive extraction, policy and bounded TypeScript checks',
                   'source': identity, 'source_root': str(Path.cwd().resolve()), 'target': args.target, 'host': host,
                   'ci_host_verified': args.ci_host, 'archive': filename,
                   'archive_sha256': archive_sha, 'node': json.loads(version.stdout),
                   'native_commands': ['help', 'version', 'init', 'validate', 'export'],
                   'typescript': installed['typescript'], 'acceptance': acceptance,
                   'installer': installer,
                   'relocation': {'extracted': str(extracted), 'executed': str(bundle),
                                  'original_removed': True}}, stream, indent=2, sort_keys=True)
        stream.write('\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-directory', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--target', choices=TARGETS, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--acceptance-fixtures', type=Path,
                        help='Prepared fixture manifest; enables the complete process acceptance gate')
    parser.add_argument('--ci-host', action='store_true')
    parser.add_argument('--installer-checks', action='store_true',
                        help='Build and exercise native installers on a disposable CI host')
    try:
        probe(parser.parse_args())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        sys.exit(f'Native release smoke failed: {error}')
