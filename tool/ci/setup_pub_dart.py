"""Ephemeral CI prerequisites for the bounded private pub snapshot route."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
from urllib.request import urlopen


def host(target):
    expected = {'linux-x64': ('Linux', 'x86_64'), 'macos-arm64': ('Darwin', 'arm64'),
                'windows-x64': ('Windows', 'amd64')}
    if (platform.system(), platform.machine().lower()) != expected[target]:
        raise ValueError('Wrong actual host target')
    if target == 'linux-x64':
        release = platform.freedesktop_os_release()
        if (release.get('ID'), release.get('VERSION_ID'), platform.libc_ver()) != (
                'ubuntu', '24.04', ('glibc', '2.39')):
            raise ValueError('Wrong actual host: Ubuntu 24.04/glibc 2.39 required')
    elif target == 'macos-arm64':
        if not platform.mac_ver()[0].startswith('15.'):
            raise ValueError('Wrong actual host: macOS 15 required')
    elif (sys.getwindowsversion().build != 26100
          or sys.getwindowsversion().product_type != 3):
        raise ValueError('Wrong actual host: Windows Server 2025 build 26100 required')
    return {'system': platform.system(), 'machine': platform.machine(),
            'version': platform.version(), 'release': platform.release()}


# Reviewed pins already used by the native setup recipes in this repository.
ARCHIVES = {
    'linux-x64': ('linux-x64', '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7'),
    'macos-arm64': ('macos-arm64', 'c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc'),
    'windows-x64': ('windows-x64', '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e'),
}


def setup(args):
    actual = host(args.target)
    root = args.output.resolve()
    if any(c.isspace() for c in str(root)):
        raise ValueError('Space-free canonical setup path required')
    root.mkdir(parents=True, exist_ok=False)
    (root / 'host.json').write_text(json.dumps(actual, indent=2), encoding='utf-8')
    suffix, expected = ARCHIVES[args.target]
    name = f'dartsdk-{suffix}-release.zip'
    url = 'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/' + name
    with urlopen(url + '.sha256sum', timeout=180) as response:
        record = response.read(1024).decode().strip()
    if not re.fullmatch(expected + r'\s+\*?' + re.escape(name), record):
        raise ValueError('Official SDK checksum record differs from reviewed pin')
    archive = root / name
    with urlopen(url, timeout=180) as response, archive.open('wb') as stream:
        shutil.copyfileobj(response, stream)
    with archive.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    (root / 'dart-integrity.json').write_text(json.dumps(
        {'url': url, 'expected_sha256': expected, 'actual_sha256': digest}), encoding='utf-8')
    if digest != expected:
        raise ValueError('SDK checksum mismatch')
    if os.name == 'nt':
        shutil.unpack_archive(str(archive), str(root))
    else:
        subprocess.run(['unzip', '-q', str(archive), '-d', str(root)], check=True, timeout=180)
    dart = root / 'dart-sdk/bin' / ('dart.exe' if os.name == 'nt' else 'dart')
    home, cache = root / 'home', root / 'prepared-cache'
    home.mkdir()
    empty_config = root / 'empty-git-config'
    empty_config.touch()
    # Do not inherit personal credentials, pub/Git configuration or loader overrides.
    env = {key: value for key, value in os.environ.items()
           if key.lower() in {'systemroot', 'windir', 'comspec', 'pathext', 'temp', 'tmp',
                              'http_proxy', 'https_proxy', 'no_proxy'}}
    setup_path = [str(dart.parent), str(Path(shutil.which('git')).parent)]
    if os.name != 'nt':
        setup_path.append(str(Path(shutil.which('chmod')).parent))
    env.update({'HOME': str(home), 'USERPROFILE': str(home), 'XDG_CONFIG_HOME': str(home),
                'PATH': os.pathsep.join(setup_path), 'PUB_CACHE': str(cache),
                'PUB_HOSTED_URL': 'https://pub.dev', 'DASH__SUPPRESS_ANALYTICS': 'true',
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(empty_config)})
    version = subprocess.run([str(dart), '--version'], env=env, capture_output=True,
                             text=True, check=True, timeout=30)
    version = version.stdout + version.stderr
    (root / 'dart-version.log').write_text(version, encoding='utf-8')
    if not re.match(r'Dart SDK version: 3\.13\.3(?:\s|$)', version):
        raise ValueError('Unexpected Dart runtime')
    if args.prepare_cache:
        with (root / 'pub-get.log').open('wb') as log:
            subprocess.run([str(dart), '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
                           cwd=args.source, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=240)
        subprocess.run(['git', '-C', str(args.source), 'diff', 'HEAD', '--exit-code'], check=True)
    with Path(os.environ['GITHUB_ENV']).open('a', encoding='utf-8') as stream:
        for key, value in {'PUB_DART': dart, 'PUB_PREPARED_CACHE': cache,
                           'PUB_PROBE_OUTPUT': root / 'probe'}.items():
            stream.write(f'{key}={value}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['linux-x64', 'macos-arm64', 'windows-x64'], required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare-cache', action='store_true')
    args = parser.parse_args()
    try:
        setup(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Pub Dart setup failed: {error}\n')


if __name__ == '__main__':
    main()
