"""Identity and isolated installation setup for the real pub process probe."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

import yaml
from installation_artifact import _inventory


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def identity(args):
    saved = read(args.stage_evidence / 'stage-identity.json')
    if saved['file_set_sha256'] != args.expected_digest:
        raise ValueError('Expected stage digest differs')
    if saved['source']['commit'] != args.expected_source:
        raise ValueError('Expected source commit differs')
    report = read(args.stage_evidence / 'report.json')
    if (report['source'] != saved['source'] or report['file_set_sha256'] != args.expected_digest
            or report['files'] != len(saved['files'])):
        raise ValueError('Producer report differs from stage identity')
    return saved


def inventory(root):
    result = {}
    for path in [root, *root.rglob('*')]:
        info = path.lstat()
        if (stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0)
                & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)):
            raise ValueError('Aliased dependency/installed file')
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Special dependency/installed file')
        result[path.relative_to(root).as_posix()] = {
            'sha256': sha(path), 'size': info.st_size, 'mode': stat.S_IMODE(info.st_mode)}
    return dict(sorted(result.items()))


def check_files(root, files):
    actual = _inventory(root, files)
    if {name: entry['sha256'] for name, entry in actual.items()} != files:
        raise ValueError('Staged file bytes differ')


def environment(base, dart, git):
    # Explicit allowlist: no inherited Git config, loader, Dart or pub overrides.
    env = {key: value for key, value in os.environ.items()
           if key.lower() in {'systemroot', 'windir', 'comspec', 'pathext', 'temp', 'tmp',
                              'http_proxy', 'https_proxy', 'no_proxy'}}
    home, hooks = base / 'home', base / 'empty-hooks'
    home.mkdir(); hooks.mkdir()
    config = base / 'empty-git-config'
    config.touch()
    setup_paths = [str(dart.parent), str(git.parent)]
    if os.name != 'nt':
        setup_paths.append(str(Path(shutil.which('chmod')).parent))
    env.update({'PATH': os.pathsep.join(setup_paths), 'HOME': str(home),
                'USERPROFILE': str(home), 'XDG_CONFIG_HOME': str(home),
                'PUB_CACHE': str(base / 'cache'), 'PUB_HOSTED_URL': 'https://pub.dev',
                'DART_SUPPRESS_ANALYTICS': 'true', 'DASH__SUPPRESS_ANALYTICS': 'true',
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(config),
                'GIT_CONFIG_SYSTEM': str(config), 'GIT_TERMINAL_PROMPT': '0'})
    settings = {'core.hooksPath': str(hooks), 'core.autocrlf': 'false',
                'commit.gpgSign': 'false', 'init.templateDir': str(hooks)}
    env['GIT_CONFIG_COUNT'] = str(len(settings))
    for index, (key, value) in enumerate(settings.items()):
        env[f'GIT_CONFIG_KEY_{index}'] = key
        env[f'GIT_CONFIG_VALUE_{index}'] = value
    return env


def run(arguments, cwd, env, log, timeout=60):
    result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(f'Process exited {result.returncode}; see {log}')
    return result


def verified_stage(args, saved, env):
    stage = args.stage_evidence / 'pub source café'
    verifier = Path(__file__).with_name('verify_pub_stage.py')
    result = run([sys.executable, str(verifier), '--stage', str(stage),
                  '--source', str(args.source), '--combined', str(args.combined),
                  '--transports', str(args.transports), '--expected-commit', args.expected_source],
                 args.output, env, args.output / 'stage-verification.json')
    if json.loads(result.stdout) != saved:
        raise ValueError('Reverified stage identity differs from producer')
    return stage


def prepare_cache(prepared, cache, lock):
    packages = yaml.safe_load(lock.read_text(encoding='utf-8'))['packages']
    expected = {}
    for name, package in packages.items():
        if package['source'] != 'hosted' or package['description']['url'] != 'https://pub.dev':
            raise ValueError('Expected only official prepared hosted dependencies')
        version = package['version']
        directory = f'{name}-{version}'
        source = prepared / 'hosted/pub.dev' / directory
        hashes = prepared / 'hosted-hashes/pub.dev' / (directory + '.sha256')
        digest = package['description']['sha256']
        if hashes.read_text().strip() != digest:
            raise ValueError('Prepared dependency archive hash differs from source lock')
        before = inventory(source)
        destination = cache / 'hosted/pub.dev' / directory
        shutil.copytree(source, destination)
        if inventory(destination) != before:
            raise ValueError('Prepared dependency copy differs')
        target_hash = cache / 'hosted-hashes/pub.dev' / hashes.name
        target_hash.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(hashes, target_hash)
        expected[name] = {'version': version, 'sha256': digest,
                          'file_set_sha256': hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest()}
    return expected, inventory(cache / 'hosted'), inventory(cache / 'hosted-hashes')


def resolved_dependencies(cache, expected, before, hash_before):
    # pub may create metadata, but no new/replaced package or hash bytes are allowed.
    actual = inventory(cache / 'hosted')
    actual = {name: value for name, value in actual.items() if not name.startswith('pub.dev/.cache/')}
    if actual != before or inventory(cache / 'hosted-hashes') != hash_before:
        raise ValueError('Activation changed prepared hosted package bytes')
    lock = cache / 'global_packages/archway/pubspec.lock'
    packages = yaml.safe_load(lock.read_text(encoding='utf-8'))['packages']
    resolved = {}
    for name, value in packages.items():
        if name == 'archway':
            if value['source'] != 'git':
                raise ValueError('Activation did not use Git')
            continue
        item = expected.get(name)
        if (item is None or value['version'] != item['version'] or value['source'] != 'hosted'
                or value['description']['sha256'] != item['sha256']
                or value['description']['url'] != 'https://pub.dev'):
            raise ValueError('Activated dependency differs from reviewed source lock')
        resolved[name] = item
    if not resolved:
        raise ValueError('No activated dependency resolution')
    return resolved


def installed_root(config, cache):
    package = next(p for p in read(config)['packages'] if p['name'] == 'archway')
    uri = urlsplit(urljoin(config.as_uri(), package['rootUri']))
    if uri.scheme != 'file' or uri.netloc not in ('', 'localhost') or uri.query or uri.fragment:
        raise ValueError('Invalid installed package file URI')
    path = Path(url2pathname(uri.path))
    if not path.is_absolute() or path != path.resolve() or not path.is_relative_to(cache / 'git'):
        raise ValueError('Installed package is outside isolated Git cache')
    return path


def actual_host(target):
    expected = {'linux-x64': ('Linux', 'x86_64'), 'macos-arm64': ('Darwin', 'arm64'),
                'windows-x64': ('Windows', 'amd64')}
    if (platform.system(), platform.machine().lower()) != expected[target]:
        raise ValueError('Wrong actual host target')
    host = {'system': platform.system(), 'machine': platform.machine(),
            'release': platform.release(), 'version': platform.version()}
    if os.name == 'nt':
        host['windows_edition'] = platform.win32_edition()
        host['windows_product_type'] = sys.getwindowsversion().product_type
    elif sys.platform == 'darwin':
        host['macos'] = platform.mac_ver()[0]
    else:
        host['os_release'] = platform.freedesktop_os_release()
    return host
