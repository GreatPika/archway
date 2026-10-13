"""All-target pub file-set or explicit registry-candidate validation; never publish.

Args: Dart, exact source checkout, combined result, original transports,
expected source commit, new evidence directory. Dependencies need no preparation
for --skip-validation: this does not establish hosted publish readiness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

import yaml

repository = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repository / 'tool/ci'))
from pub_stage_inventory import inspect_upload_archive, validate_pub_advisories, UPLOAD_ARCHIVE
from pub_snapshot_setup import inventory, prepare_cache

parser = argparse.ArgumentParser(description=__doc__)
for name in ['dart', 'source', 'combined', 'transports']:
    parser.add_argument(name, type=lambda value: Path(value).absolute())
parser.add_argument('commit')
parser.add_argument('output', type=lambda value: Path(value).absolute())
parser.add_argument('--registry-ready', action='store_true')
parser.add_argument('--prepared-cache', type=lambda value: Path(value).absolute())
args = parser.parse_args()
dart, source, combined, transports = args.dart, args.source, args.combined, args.transports
commit, output = args.commit, args.output
output.mkdir(parents=True, exist_ok=False)
stage = output / 'pub source café'
version = subprocess.run([str(dart), '--version'], capture_output=True,
                         text=True, check=True, timeout=30)
version = (version.stdout + version.stderr).strip()
assert re.match(r'Dart SDK version: 3\.13\.3(?:\s|$)', version), version
result = subprocess.run([sys.executable, str(source / 'tool/package_delivery.py'),
                         'pub', str(stage), str(combined / 'installation'),
                         *(['--registry-ready'] if args.registry_ready else [])],
                        capture_output=True, text=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
command = [sys.executable, str(repository / 'tool/ci/verify_pub_stage.py'),
           '--stage', str(stage), '--source', str(source), '--combined', str(combined),
           '--transports', str(transports), '--expected-commit', commit,
           *(['--registry-ready'] if args.registry_ready else [])]
result = subprocess.run(command, capture_output=True, text=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
identity = json.loads(result.stdout)
(output / 'stage-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
home = output / 'home'
home.mkdir()
environment = {key: value for key, value in os.environ.items()
               if key in ['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TEMP', 'TMP']}
environment.update({'HOME': str(home), 'USERPROFILE': str(home),
                    'PUB_CACHE': str(output / 'dry-run-cache'),
                    'PATH': str(dart.parent), 'DART_SUPPRESS_ANALYTICS': 'true'})
if args.registry_ready:
    # Resolution files and logs never enter the immutable publishable stage.
    working = output / 'validation copy café'
    shutil.copytree(stage, working)
    shutil.copy2(source / 'pubspec.lock', working / 'pubspec.lock')
    cache = Path(environment['PUB_CACHE'])
    if args.prepared_cache is not None:
        prepare_cache(args.prepared_cache, cache, source / 'pubspec.lock')
    git = shutil.which('git')
    if git is None:
        raise ValueError('Full pub validation requires git on PATH')
    environment['PATH'] = os.pathsep.join([str(dart.parent), str(Path(git).parent)])
    environment['PUB_HOSTED_URL'] = 'https://pub.dev'
    for key, value in os.environ.items():
        if key.lower() in {'http_proxy', 'https_proxy', 'no_proxy'}:
            environment[key] = value

    def check_working():
        current = inventory(working)
        published = {name: entry['sha256'] for name, entry in current.items()
                     if not name.startswith('.dart_tool/') and name != 'pubspec.lock'}
        if published != identity['files']:
            raise ValueError('Validation copy changed publishable file bytes')
        if hashlib.sha256((working / 'pubspec.lock').read_bytes()).hexdigest() != identity['source']['lockfile_sha256']['pubspec.lock']:
            raise ValueError('Pub validation changed the reviewed dependency lock')

    def dependencies():
        packages = yaml.safe_load((working / 'pubspec.lock').read_text())['packages']
        result = {}
        for name, package in packages.items():
            if package['source'] != 'hosted' or package['description']['url'] != 'https://pub.dev':
                raise ValueError('Pub candidate has a nonofficial hosted dependency')
            directory = name + '-' + package['version']
            digest = package['description']['sha256']
            if (cache / 'hosted-hashes/pub.dev' / (directory + '.sha256')).read_text().strip() != digest:
                raise ValueError('Resolved dependency archive hash differs from source lock')
            result[name] = {'version': package['version'], 'sha256': digest,
                'files': inventory(cache / 'hosted/pub.dev' / directory)}
        return hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()

    def run_validation(label, options, export=False):
        invocation = [str(dart), '--suppress-analytics', 'pub', 'publish', *options]
        (output / (label + '-command.json')).write_text(json.dumps(invocation) + '\n')
        with (output / (label + '-stdout.log')).open('wb') as out, (output / (label + '-stderr.log')).open('wb') as err:
            try:
                completed = subprocess.run(invocation, cwd=working, env=environment,
                                           stdout=out, stderr=err, timeout=180)
            except subprocess.TimeoutExpired:
                (output / (label + '-status.json')).write_text('{"timeout_seconds":180}\n')
                raise
        (output / (label + '-status.json')).write_text(json.dumps({'exit_code': completed.returncode}) + '\n')
        stdout = (output / (label + '-stdout.log')).read_text()
        stderr = (output / (label + '-stderr.log')).read_text()
        (output / (label + '.log')).write_text(stdout + stderr)
        return validate_pub_advisories(stdout, stderr, completed.returncode, export=export)

    check_working()
    dry_proof = run_validation('dry-run', ['--dry-run'])
    check_working(); dependency_identity = dependencies()
    archive = output / UPLOAD_ARCHIVE
    export_proof = run_validation('archive-export', ['--to-archive', str(archive)], export=True)
    check_working()
    if dependencies() != dependency_identity:
        raise ValueError('Dependency bytes changed between validation and archive export')
    archive_proof = inspect_upload_archive(archive, identity['files'])
    after = subprocess.run(command, capture_output=True, text=True, timeout=60)
    assert after.returncode == 0, (after.stdout, after.stderr)
    assert json.loads(after.stdout) == identity, 'Validation changed immutable staged identity'
    identity['upload_archive'] = archive_proof
    (output / 'stage-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    report = {'route': 'all-target pub candidate validation and exact upload archive',
              'validation': 'validated with 7 expected tight-pin advisories; no hosted installation proof',
              'registry_ready': True, 'dart': version, 'source': identity['source'],
              'files': len(identity['files']), 'file_set_sha256': identity['file_set_sha256'],
              'upload_archive': archive_proof, 'dry_run': dry_proof, 'archive_export': export_proof,
              'dependency_identity_sha256': dependency_identity}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, sort_keys=True))
    sys.exit(0)

result = subprocess.run([str(dart), '--suppress-analytics', 'pub', '--verbose',
                         'publish', '--dry-run', '--skip-validation'], cwd=stage,
                        env=environment, capture_output=True, text=True, timeout=90)
log = result.stdout + result.stderr
(output / 'dry-run.log').write_text(log)
assert result.returncode == 0, (result.stdout, result.stderr)
marker = 'Creating .tar.gz stream containing:'
assert log.count(marker) == 1, 'Expected one pinned-Dart file listing'
# Do not discard unknown or absent paths: compare the complete verbose listing.
paths = re.findall(r'^    \| \./(.+)$', log.split(marker, 1)[1], re.MULTILINE)
assert len(paths) == len(set(paths)), 'Duplicate dry-run path'
expected_paths = set(identity['files']) | {'.'}
for name in identity['files']:
    expected_paths.update(parent.as_posix() for parent in PurePosixPath(name).parents)
assert set(paths) == expected_paths, {
    'missing': sorted(expected_paths - set(paths)),
    'extra': sorted(set(paths) - expected_paths)}
after = subprocess.run(command, capture_output=True, text=True, timeout=60)
assert after.returncode == 0, (after.stdout, after.stderr)
assert json.loads(after.stdout) == identity, 'Dry-run changed staged identity'
report = {'route': 'private all-target pub dry-run file-set inclusion',
          'validation': 'skipped; no archive-byte, activation, or hosted publish readiness proof',
          'dart': version, 'source': identity['source'], 'files': len(identity['files']),
          'listed_entries_including_directories': len(paths),
          'file_set_sha256': identity['file_set_sha256'],
          'dry_run_log_sha256': hashlib.sha256(log.encode()).hexdigest()}
(output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, sort_keys=True))
