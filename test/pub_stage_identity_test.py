"""Bounded public verifier CLI controls; caller supplies genuine staged evidence."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main(argv=None):
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['stage', 'source', 'combined', 'transports', 'commit']:
        parser.add_argument(name)
    parser.add_argument('--registry-ready', action='store_true')
    args = parser.parse_args(argv)
    stage, source, combined, transports, commit = (
        args.stage, args.source, args.combined, args.transports, args.commit)
    command = [sys.executable, str(repo / 'tool/ci/verify_pub_stage.py'),
               '--stage', stage, '--source', source, '--combined', combined,
               '--transports', transports, '--expected-commit', commit]
    if args.registry_ready:
        command.append('--registry-ready')

    def check(ok):
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
        return result

    check(True)
    manifest = Path(stage) / 'manifest.json'
    original = manifest.read_bytes()
    try:
        value = json.loads(original)
        value['partial'] = True
        manifest.write_text(json.dumps(value))
        check(False)
    finally:
        manifest.write_bytes(original)
    print('PASS all-target manifest identity control')

    # Each mutation is restored before the next independent verifier invocation.
    for relative, operation in [
        ('native/windows-x64/archway_io.dll', 'missing'),
        ('bin/archway.dart', 'corrupt'),
        ('assets/typescript/licenses/pnpm-MIT.txt', 'corrupt'),
        ('schemas/public-result.schema.json', 'corrupt'),
        ('pubspec.yaml', 'corrupt'),
    ]:
        path = Path(stage) / relative
        saved = path.read_bytes()
        try:
            if operation == 'missing':
                path.unlink()
            else:
                path.write_bytes(saved + b'\nchanged\n')
            check(False)
        finally:
            path.write_bytes(saved)
        print('PASS rejected', operation, relative)
    extra = Path(stage) / 'unexpected.txt'
    try:
        extra.write_text('unreviewed')
        check(False)
    finally:
        extra.unlink()
    print('PASS rejected extra file')
    extra_dir = Path(stage) / 'unexpected-empty'
    try:
        extra_dir.mkdir()
        check(False)
    finally:
        extra_dir.rmdir()
    print('PASS rejected extra directory')
    path = Path(stage) / 'bin/archway.dart'
    saved = path.read_bytes()
    try:
        path.unlink()
        path.symlink_to(Path(source).absolute() / 'bin/archway.dart')
        check(False)
    finally:
        path.unlink()
        path.write_bytes(saved)
    print('PASS rejected aliased source')
    for field, value in [('targets', ['linux-x64']), ('private', args.registry_ready)]:
        try:
            changed = json.loads(original)
            changed[field] = value
            manifest.write_text(json.dumps(changed))
            check(False)
        finally:
            manifest.write_bytes(original)
        print('PASS rejected', field)
    commit_index = command.index('--expected-commit') + 1
    command[commit_index] = '0' * 40
    check(False)
    command[commit_index] = commit
    print('PASS rejected wrong source commit')
    check(True)


if __name__ == '__main__':
    main()
