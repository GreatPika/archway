"""Portable installed pub launcher proof; no hosted-installation certification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess

from aot_init_assertions import assert_aot_init
from pub_snapshot_analysis import exercise as analysis
from npm_local_install_probe import command
from pub_stage_transport import expectation, read_transport
from pub_snapshot_setup import (actual_host, check_files, environment, identity,
    installed_root, inventory, prepare_cache, resolved_dependencies, run, sha, verified_stage)


def remove_disposable_source(source):
    def retry_read_only_unlink(function, path, error):
        # Git objects are read-only; Windows refuses to unlink them until the
        # write bit is restored. Only retry that specific removal, once.
        if function is not os.unlink or not isinstance(error, PermissionError):
            raise error
        mode = Path(path).lstat().st_mode
        if not stat.S_ISREG(mode) or mode & stat.S_IWUSR:
            raise error
        os.chmod(path, mode | stat.S_IWUSR)
        function(path)

    shutil.rmtree(source, onexc=retry_read_only_unlink)


def runtime_environment(env, dart, output):
    runtime = output / 'launcher-runtime'
    runtime.mkdir()
    if os.name != 'nt':
        shell = shutil.which('sh')
        if shell is None:
            raise ValueError('Required pub launcher shell unavailable')
        (runtime / 'sh').symlink_to(Path(shell).resolve())
    result = {key: value for key, value in env.items() if 'proxy' not in key.lower()}
    result.update({'PATH': str(runtime) + os.pathsep + str(dart.parent),
                   'http_proxy': 'http://127.0.0.1:9', 'https_proxy': 'http://127.0.0.1:9',
                   'HTTP_PROXY': 'http://127.0.0.1:9', 'HTTPS_PROXY': 'http://127.0.0.1:9',
                   'NO_PROXY': '', 'no_proxy': ''})
    if shutil.which('node', path=result['PATH']) is not None:
        raise ValueError('Node is available in installed-command runtime')
    return result


def phase(launcher, output, env):
    output.mkdir()
    cwd = output / 'foreign cwd café'
    cwd.mkdir()
    results = []
    for flag in ['--help', '--version']:
        result = run(command([str(launcher), flag]), cwd, env, output / (flag[2:] + '.log'))
        if result.stderr:
            raise ValueError('Installed command emitted unexpected stderr')
        if flag == '--version' and result.stdout != b'archway 0.1.0\n':
            raise ValueError('Installed version differs')
        if flag == '--help' and not result.stdout.startswith(b'archway [--root ROOT] COMMAND [OPTIONS]\n'):
            raise ValueError('Installed help differs')
        results.append({'arguments': [flag], 'exit': result.returncode,
                        'stdout_sha256': hashlib.sha256(result.stdout).hexdigest()})
    if list(cwd.iterdir()):
        raise ValueError('Help/version changed foreign cwd')
    # Reuse the established exact mixed-init oracle, while identifying this
    # route as pub snapshot (the helper's historical name is AOT-specific).
    init = output / 'mixed-init'
    init.mkdir()
    result = assert_aot_init(launcher, init, command=command, environment=env, label='Pub snapshot')
    (output / 'init.log').write_bytes(result.stdout + result.stderr)
    return {'commands': results + [{'arguments': ['init', '--template', 'mixed'], 'exit': 0}],
            'init_files': inventory(init / 'empty project café')}


def generated_snapshots(cache):
    global_root = cache / 'global_packages/archway'
    launcher = cache / 'bin' / ('archway.bat' if os.name == 'nt' else 'archway')
    # Dart 3.13.3 pub precompiles every bin/*.dart entry, including setup.dart.
    # Select the CLI snapshot by its pinned path, never by enumeration order.
    snapshot = global_root / 'bin/archway.dart-3.13.3.snapshot'
    expected = {snapshot, global_root / 'bin/setup.dart-3.13.3.snapshot'}
    if set(global_root.rglob('*.snapshot')) != expected:
        raise ValueError('Expected exactly the pinned archway and setup snapshots')
    for path in [launcher, *expected]:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_size == 0
                or getattr(info, 'st_file_attributes', 0)
                & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)
                or path.resolve() != path.absolute()):
            raise ValueError('Generated launcher/snapshot must be ordinary and unaliased')
    return launcher, snapshot


def probe(args):
    registry_ready = getattr(args, 'registry_ready', False)
    if registry_ready and not args.transport_archive:
        raise ValueError('Registry-ready probe requires authenticated archive transport')
    transport = None
    if args.transport_archive:
        transport = expectation(args.expected_transport_json, args.expected_source,
                                args.run_id, args.run_attempt, registry_ready=registry_ready)
    else:
        saved = identity(args)
    host = actual_host(args.target)
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Evidence output already exists')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    git_path = shutil.which('git')
    if git_path is None:
        raise ValueError('Git is unavailable')
    git = Path(git_path).absolute()
    env = environment(args.output, args.dart, git)
    version = run([str(args.dart), '--version'], args.output, env, args.output / 'dart-version.log')
    version = (version.stdout + version.stderr).decode('utf-8').strip()
    if not re.match(r'Dart SDK version: 3\.13\.3(?:\s|$)', version):
        raise ValueError('Expected actual Dart 3.13.3')
    if transport:
        args.stage_evidence = args.output / 'received-stage'
        receipt = read_transport(args.transport_archive, transport, args.source, args.stage_evidence,
                                 registry_ready=registry_ready)
        (args.output / 'transport-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
        args.expected_digest = transport['file_set_sha256']
        saved = identity(args)
        stage = args.stage_evidence / 'pub source café'
    else:
        stage = verified_stage(args, saved, env)
    source = args.output / 'disposable Git source café'
    shutil.copytree(stage, source)
    check_files(source, saved['files'])
    cache = args.output / 'cache café with spaces'
    env['PUB_CACHE'] = str(cache)
    expected, before, hash_before = prepare_cache(args.prepared_cache, cache, args.source / 'pubspec.lock')
    for number, arguments in enumerate([
        ['init', '-q', str(source)], ['-C', str(source), 'add', '.'],
        ['-C', str(source), '-c', 'user.name=Installation fixture', '-c',
         'user.email=fixture@example.invalid', 'commit', '-qm', 'Prepared installation fixture']]):
        run([str(git), *arguments], args.output, env, args.output / f'git-{number}.log')
    fixture = run([str(git), '-C', str(source), 'rev-parse', 'HEAD'], args.output, env,
                  args.output / 'fixture-commit.log').stdout.decode().strip()
    activation = [str(args.dart), '--suppress-analytics', 'pub', '--verbose', 'global',
                  'activate', '--source', 'git', '--git-ref', fixture, source.as_uri()]
    run(activation, args.output, env, args.output / 'activation.log', timeout=240)
    dependencies = resolved_dependencies(cache, expected, before, hash_before)
    log = (args.output / 'activation.log').read_text(encoding='utf-8')
    requests = sorted(set(re.findall(r'HTTP GET (\S+)', log)))
    if any(not re.fullmatch(r'https://pub\.dev/api/packages/[a-z0-9_]+', uri) for uri in requests):
        raise ValueError('Unexpected activation network request or package archive download')
    global_root = cache / 'global_packages/archway'
    installed = installed_root(global_root / '.dart_tool/package_config.json', cache)
    files = inventory(installed)
    for name, digest in saved['files'].items():
        if name not in files or files[name]['sha256'] != digest:
            raise ValueError('Installed staged hash differs: ' + name)
    extras = sorted(set(files) - set(saved['files']))
    if any(not (name.startswith(('.git/', '.dart_tool/')) or name == 'pubspec.lock') for name in extras):
        raise ValueError('Unexpected installed package file')
    launcher, snapshot = generated_snapshots(cache)
    generated_launcher_sha256 = sha(launcher)
    run([str(args.dart), 'pub', 'global', 'run', 'archway:setup'], args.output, env,
        args.output / 'launcher-setup.log', timeout=90)
    hashes = {'launcher': sha(launcher), 'snapshot': sha(snapshot)}
    runtime = runtime_environment(env, args.dart, args.output)
    first = phase(launcher, args.output / 'installed', runtime)
    remove_disposable_source(source)
    entrypoint = installed / 'bin/archway.dart'
    entrypoint.write_text('THIS IS INTENTIONALLY INVALID DART !!!\n', encoding='utf-8')
    control = subprocess.run([str(args.dart), str(entrypoint), '--version'],
        cwd=args.output, env=runtime, capture_output=True, timeout=45)
    (args.output / 'poisoned-source-control.log').write_bytes(control.stdout + control.stderr)
    if control.returncode == 0:
        raise ValueError('Poisoned direct source unexpectedly ran')
    global_run = run([str(args.dart), 'pub', 'global', 'run', 'archway:archway', '--version'],
        args.output, runtime, args.output / 'snapshot-global-run.log')
    if global_run.stderr or global_run.stdout != b'archway 0.1.0\n':
        raise ValueError('Explicit pub global run did not use the clean snapshot')
    second = phase(launcher, args.output / 'poisoned-source-snapshot', runtime)
    checks = analysis(launcher, installed, args.node, args.target, args.output / 'analysis', runtime)
    if {'launcher': sha(launcher), 'snapshot': sha(snapshot)} != hashes:
        raise ValueError('Repaired launcher/snapshot changed during proof')
    check_files(stage, saved['files'])
    resolved_dependencies(cache, expected, before, hash_before)
    report = {'route': 'isolated local Git activation, explicit setup and pub-generated snapshot',
        'scope': 'help/version/init, policy/export and TypeScript asset controls; not hosted installation or target certification',
        'analysis': checks,
        **({'registry_ready': True} if registry_ready else {}),
        'source': saved['source'], 'file_set_sha256': args.expected_digest, 'transport': transport,
        'staged_files_verified': len(saved['files']), 'fixture_commit': fixture,
        'dart': version, 'host': host, 'target': args.target, 'dependencies': dependencies,
        'activation': {'command': activation, 'registry_metadata_requests': requests,
                       'network_required': True, 'package_downloads': False,
                       'log_sha256': sha(args.output / 'activation.log')},
        'runtime': {'node_available': False, 'network': 'dead-loopback HTTP(S) proxy; not OS sandbox',
                    'path': runtime['PATH']},
        'launcher': str(launcher), 'snapshot': str(snapshot), 'sha256': hashes,
        'generated_launcher_sha256': generated_launcher_sha256,
        'pub_generated_files': extras, 'phases': {'installed': first, 'poisoned_source_snapshot': second}}
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['dart', 'source', 'prepared-cache', 'node']:
        parser.add_argument('--' + name, type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument('--output', type=lambda value: Path(value).absolute(), required=True)
    parser.add_argument('--expected-source', required=True)
    parser.add_argument('--expected-digest')
    for name in ['stage-evidence', 'combined', 'transports', 'transport-archive']:
        parser.add_argument('--' + name, type=lambda value: Path(value).absolute())
    for name in ['expected-transport-json', 'run-id', 'run-attempt']:
        parser.add_argument('--' + name)
    parser.add_argument('--target', choices=['linux-x64', 'macos-arm64', 'windows-x64'], required=True)
    parser.add_argument('--registry-ready', action='store_true')
    args = parser.parse_args()
    try:
        local = [args.stage_evidence, args.combined, args.transports, args.expected_digest]
        transferred = [args.expected_transport_json, args.run_id, args.run_attempt]
        if args.transport_archive:
            if any(local) or not all(transferred):
                raise ValueError('Transport route requires only caller-bound transport inputs')
        elif not all(local) or any(transferred):
            raise ValueError('Local route requires full original verifier inputs')
        probe(args)
    except (ValueError, OSError, KeyError, TypeError, AssertionError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Pub snapshot acceptance failed: {error}\n')


if __name__ == '__main__':
    main()
