"""Prepare genuine pinned fixtures before offline native acceptance, never in check."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import urlopen, url2pathname

FLUTTER_VERSION = '3.47.4'
DART_VERSION = '3.13.3'
GIT_URL = 'https://github.com/dart-lang/core.git'
GIT_REF = '4d80610a878cdb3f9f10e6a16a2af6631251a3c6'
FLUTTER_BASE = 'https://storage.googleapis.com/flutter_infra_release/releases/'
# Official release indexes, retrieved 2026-10-12; also revalidated during setup.
FLUTTER = {
    'linux-x64': ('stable/linux/flutter_linux_3.47.4-stable.tar.xz',
                  '5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3'),
    'macos-arm64': ('stable/macos/flutter_macos_arm64_3.47.4-stable.zip',
                    'c6af6fa1d64946167b8637ba4c5a7bb3b8574729a1ebe931decd4924dbab7061'),
    'windows-x64': ('stable/windows/flutter_windows_3.47.4-stable.zip',
                    '31173300481bd06e377fd55ee84214689648b1817563efd7b450b7b78bdf351a'),
}
NODE = {
    'linux-x64': ('linux-x64.tar.gz', 'f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4'),
    'macos-arm64': ('darwin-arm64.tar.gz', '8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d'),
    'windows-x64': ('win-x64.zip', '57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73'),
}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding='utf-8')


def flutter_record(index, target):
    archive, digest = FLUTTER[target]
    matches = [r for r in index['releases'] if r.get('version') == FLUTTER_VERSION
               and r.get('channel') == 'stable'
               and r.get('dart_sdk_arch') == target.split('-')[1]]
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous official Flutter pin')
    record = matches[0]
    if (record.get('archive'), record.get('sha256'), record.get('dart_sdk_version')) != (
            archive, digest, DART_VERSION):
        raise ValueError('Official Flutter metadata differs from reviewed pins')
    return record


def download(url, path, expected=None):
    # Retry only transient upstream gateway/service failures, never bad bytes.
    for attempt in range(3):
        try:
            with urlopen(url, timeout=180) as response, path.open('wb') as out:
                shutil.copyfileobj(response, out)
            break
        except HTTPError as error:
            error.close()
            if error.code not in (502, 503, 504):
                raise
            path.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(attempt + 1)
    if expected is not None and sha(path) != expected:
        raise ValueError(f'Archive checksum mismatch: {path.name}')


def unpack(archive, root):
    # Verified official archives only. unzip preserves Unix executable modes.
    if archive.suffix == '.zip' and os.name != 'nt':
        subprocess.run(['unzip', '-q', str(archive), '-d', str(root)], check=True, timeout=300)
    else:
        shutil.unpack_archive(str(archive), str(root))


def environment(root, dart, flutter):
    home, cache = root / 'home', root / 'pub-cache'
    home.mkdir()
    cache.mkdir()
    config = root / 'empty-gitconfig'
    config.touch()
    hooks = root / 'empty-hooks'
    hooks.mkdir()
    env = {k: v for k, v in os.environ.items() if k.lower() in {
        'systemroot', 'windir', 'comspec', 'pathext', 'temp', 'tmp',
        'http_proxy', 'https_proxy', 'no_proxy'}}
    git = shutil.which('git')
    if not git:
        raise ValueError('Real Git executable required')
    paths = [str(dart.parent), str(Path(git).parent)]
    if os.name == 'nt':
        paths.append(str(Path(os.environ['SystemRoot']) / 'System32'))
    else:
        paths += ['/usr/bin', '/bin']
    env.update(HOME=str(home), USERPROFILE=str(home), XDG_CONFIG_HOME=str(home / '.config'),
               XDG_CACHE_HOME=str(home / '.cache'), PUB_CACHE=str(cache),
               PUB_HOSTED_URL='https://pub.dev', PATH=os.pathsep.join(paths),
               FLUTTER_ROOT=str(flutter), FLUTTER_SDK=str(flutter),
               DART_SUPPRESS_ANALYTICS='true', DASH__SUPPRESS_ANALYTICS='true',
               FLUTTER_SUPPRESS_ANALYTICS='true', CI='true',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(config),
               GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.hooksPath',
               GIT_CONFIG_VALUE_0=str(hooks), GIT_TERMINAL_PROMPT='0')
    return env


def run(command, env, log, cwd=None, timeout=240):
    result = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                            capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    write(log, output)
    if result.returncode:
        raise ValueError(f'Preparation failed: {command[0]} (see {log})\n{output[-3000:]}')
    return output.strip()


def readiness(root):
    evidence = {}
    for name in ['pub/hosted', 'pub/path', 'pub/workspace', 'git-fixture', 'flutter-fixture']:
        paths = ['pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json']
        evidence[name] = {p: sha(root / name / p) for p in paths}
        config = json.loads((root / name / paths[-1]).read_text())
        if config.get('configVersion') != 2 or config.get('generatorVersion') != DART_VERSION:
            raise ValueError(f'Invalid prepared package config: {name}')
    return evidence


def prepare(args):
    from installation_artifact import source_identity
    source = Path(__file__).resolve().parents[2]
    source_record = source_identity(source)
    expected = {'linux-x64': ('Linux', 'x86_64'), 'macos-arm64': ('Darwin', 'arm64'),
                'windows-x64': ('Windows', 'amd64')}
    if (platform.system(), platform.machine().lower()) != expected[args.target]:
        raise ValueError('Fixture target differs from actual host')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    logs = root / 'logs'
    logs.mkdir()
    host = args.target.split('-')[0]
    index_url = FLUTTER_BASE + f'releases_{host}.json'
    index_path = root / 'flutter-index.json'
    download(index_url, index_path)
    record = flutter_record(json.loads(index_path.read_text()), args.target)
    archive = args.flutter_archive.resolve() if args.flutter_archive else root / Path(record['archive']).name
    if args.flutter_archive:
        if sha(archive) != record['sha256']:
            raise ValueError('Supplied official Flutter archive checksum mismatch')
    else:
        download(FLUTTER_BASE + record['archive'], archive, record['sha256'])
    unpack(archive, root)
    flutter = root / 'flutter'
    dart_sdk = flutter / 'bin/cache/dart-sdk'
    dart = dart_sdk / 'bin' / ('dart.exe' if os.name == 'nt' else 'dart')
    env = environment(root, dart, flutter)
    version = run([dart, '--version'], env, logs / 'dart-version.log')
    if not version.startswith('Dart SDK version: 3.13.3 '):
        raise ValueError('Wrong embedded Dart runtime')
    sdk_meta = json.loads((flutter / 'bin/cache/flutter.version.json').read_text())
    if (sdk_meta['frameworkVersion'], sdk_meta['dartSdkVersion']) != (FLUTTER_VERSION, DART_VERSION):
        raise ValueError('Extracted Flutter SDK metadata differs from pins')
    run([dart, source / 'tool/ci/verify_export_sources.dart',
         args.expected_commit], env, logs / 'export-source-verification.log', source)
    node_name = 'node-v24.19.0-' + NODE[args.target][0]
    node_base = 'https://nodejs.org/dist/v24.19.0/'
    download(node_base + 'SHASUMS256.txt', root / 'node-shasums.txt')
    records = [line.split() for line in (root / 'node-shasums.txt').read_text().splitlines()]
    if [r[0] for r in records if r[1] == node_name] != [NODE[args.target][1]]:
        raise ValueError('Official wrong-Node checksum differs from pin')
    node_archive = root / node_name
    download(node_base + node_name, node_archive, NODE[args.target][1])
    unpack(node_archive, root)
    node_dir = root / node_name.removesuffix('.tar.gz').removesuffix('.zip')
    wrong_node = node_dir / ('node.exe' if os.name == 'nt' else 'bin/node')
    if run([wrong_node, '--version'], env, logs / 'wrong-node-version.log') != 'v24.19.0':
        raise ValueError('Wrong negative-control Node runtime')
    run([dart, '--suppress-analytics', 'pub', 'cache', 'add', 'collection', '--version', '1.19.1'],
        env, logs / 'collection-cache.log')
    source = Path(__file__).resolve().parents[2]
    run([sys.executable, source / 'test/prepare_package_process_pub.py', root / 'pub', dart],
        env, logs / 'pub-fixtures.log')
    spec = 'name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n'
    git_fixture, flutter_fixture = root / 'git-fixture', root / 'flutter-fixture'
    write(git_fixture / 'pubspec.yaml', spec +
          f'dependencies:\n  path:\n    git:\n      url: {GIT_URL}\n      ref: {GIT_REF}\n      path: pkgs/path\n')
    write(flutter_fixture / 'pubspec.yaml', spec.replace('name: fixture', 'name: flutter_fixture') +
          'dependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n')
    for fixture in [git_fixture, flutter_fixture]:
        run([dart, '--suppress-analytics', 'pub', 'get'], env, logs / (fixture.name + '.log'), fixture)
    config = json.loads((git_fixture / '.dart_tool/package_config.json').read_text())
    uri = next(p['rootUri'] for p in config['packages'] if p['name'] == 'path')
    if not uri.startswith('file:'):
        raise ValueError('Git package cache origin must be absolute')
    package = Path(url2pathname(uri.removeprefix('file://'))).resolve()
    checkout = package.parent.parent
    if package != Path(env['PUB_CACHE']) / 'git' / ('core-' + GIT_REF) / 'pkgs/path':
        raise ValueError('Git package resolved outside pinned isolated cache')
    git = shutil.which('git')
    head = run([git, '-C', checkout, 'rev-parse', 'HEAD'], env, logs / 'git-head.log')
    origin = run([git, '-C', checkout, 'remote', 'get-url', 'origin'], env, logs / 'git-origin.log')
    # Pub clone origin is its isolated local bare cache, whose origin is official.
    cache_origin = run([git, '-C', origin, 'remote', 'get-url', 'origin'], env, logs / 'git-cache-origin.log')
    if head != GIT_REF or cache_origin != GIT_URL:
        raise ValueError('Git checkout or upstream differs from pin')
    lock = (git_fixture / 'pubspec.lock').read_text()
    if any(value not in lock for value in [GIT_URL, GIT_REF, 'pkgs/path', 'source: git']):
        raise ValueError('Git lock does not preserve pinned provenance')
    env.update(ARCHWAY_PUB_GIT_FIXTURE=str(git_fixture), ARCHWAY_FLUTTER_FIXTURE=str(flutter_fixture))
    if source_identity(source) != source_record:
        raise ValueError('Source changed during native fixture preparation')
    manifest = dict(schema_version=1, source=source_record, target=args.target, dart_sdk=str(dart_sdk),
                    wrong_node=str(wrong_node), pub_fixture=str(root / 'pub'),
                    git_fixture=str(git_fixture), flutter_sdk=str(flutter), flutter_fixture=str(flutter_fixture),
                    environment={k: v for k, v in env.items() if k.lower() not in {
                        'http_proxy', 'https_proxy', 'no_proxy'}},
                    pins=dict(flutter=dict(index_url=index_url, **record), dart=DART_VERSION,
                              wrong_node=dict(version='24.19.0', url=node_base + node_name,
                                              sha256=NODE[args.target][1]),
                              git=dict(url=GIT_URL, ref=head, path='pkgs/path', cache_origin=cache_origin,
                                       package_pubspec_sha256=sha(package / 'pubspec.yaml')),
                              collection='1.19.1'), readiness=readiness(root))
    output = root / 'acceptance-fixtures.json'
    write(output, json.dumps(manifest, indent=2) + '\n')
    print(output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, choices=FLUTTER)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--flutter-archive', type=Path, help='Reuse an official archive; verify its pinned checksum')
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Native acceptance preparation failed: {error}\n')


if __name__ == '__main__':
    main()
