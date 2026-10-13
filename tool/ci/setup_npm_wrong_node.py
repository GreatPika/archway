"""Prepare only the official negative-control Node, before npm inspection."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from prepare_native_acceptance import NODE, download, sha, unpack


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=NODE, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    suffix, checksum = NODE[args.target]
    filename = 'node-v24.19.0-' + suffix
    url = 'https://nodejs.org/dist/v24.19.0/'
    archive = args.archive.resolve() if args.archive else root / filename
    if not args.archive:
        sums = root / 'SHASUMS256.txt'
        download(url + 'SHASUMS256.txt', sums)
        records = [line.split() for line in sums.read_text().splitlines()]
        if [r[0] for r in records if r[1] == filename] != [checksum]:
            raise ValueError('Official wrong-Node checksum differs from reviewed pin')
        download(url + filename, archive, checksum)
    if sha(archive) != checksum:
        raise ValueError('Wrong-Node archive checksum mismatch')
    unpack(archive, root)
    directory = root / filename.removesuffix('.tar.gz').removesuffix('.zip')
    node = directory / ('node.exe' if args.target == 'windows-x64' else 'bin/node')
    environment = {k: v for k, v in os.environ.items()
                   if k.lower() not in {'node_options', 'node_path'}}
    result = subprocess.run([str(node), '--version'], env=environment,
                            capture_output=True, timeout=30, check=True)
    assert result.stdout.strip() == b'v24.19.0' and result.stderr == b''
    record = {'target': args.target, 'version': '24.19.0', 'url': url + filename,
              'archive_sha256': checksum, 'executable': str(node), 'executable_sha256': sha(node)}
    (root / 'runtime.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    if os.environ.get('GITHUB_ENV'):
        assert not any(c in str(node) for c in '\r\n')
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as stream:
            stream.write('ARCHWAY_WRONG_NODE=' + str(node) + '\n')
    print(json.dumps(record))


if __name__ == '__main__':
    main()
