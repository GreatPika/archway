"""Append matching native-host receipts; never rebuild tested release payloads."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

from combine_installations import MAX_JSON, MAX_TOTAL, canonical, ordinary, read_record
from installation_artifact import _sha256, source_identity
from pub_stage_transport import expectation
from release_acceptance_receipts import validate_pub, validate_npm, validate_native, one
from release_source_receipts import validate_source
from release_npm_runtime_receipts import validate_npm_runtime
from release_npm_termination_receipts import validate_npm_termination
from release_native_smoke import archive_manifest
from release_installer_receipts import validate_installer

TARGETS = ('linux-x64', 'macos-arm64', 'windows-x64')
COMMANDS = ['help', 'version', 'init', 'validate', 'export']
CASES = [('clean', 0), ('dependency-violation', 1), ('unsupported-option', 64),
         ('missing-owned-helper', 2), ('restored-clean', 0)]
EVIDENCE = 'archway-0.1.0-evidence.zip'


def installed_receipts(root, source, sums, args):
    if not all((args.run_id, args.run_attempt, args.expected_pub_transport_json)):
        raise ValueError('Installed receipts require independently bound source/run/transport inputs')
    registry_ready = getattr(args, 'registry_ready', False)
    transport = expectation(args.expected_pub_transport_json, source['commit'], args.run_id, args.run_attempt,
                            registry_ready=registry_ready)
    if transport['source'] != source:
        raise ValueError('Expected pub transport source differs')
    suffix = args.run_id + '-' + args.run_attempt
    routes = {'local': 'local-devDependency', 'global': 'global-prefix', 'cache': 'npm-exec-cache'}
    expected = {'npm': {f'npm-installed-{r}-{t}-{suffix}': (t, r) for t in TARGETS for r in routes},
                'pub': {f'pub-installed-{t}-{suffix}': (t, None) for t in TARGETS}}
    if {p.name for p in root.iterdir()} != set(expected):
        raise ValueError('Unexpected installed-evidence channels')
    for channel, directories in expected.items():
        if {p.name for p in (root / channel).iterdir()} != set(directories):
            raise ValueError('Missing, duplicate or wrong-run installed artifact directory')
        for name, (target, route) in directories.items():
            reports = list((root / channel / name).rglob('report.json'))
            if len(reports) != 1:
                raise ValueError('Expected one report for each installed target/route')
            proof = read_record(reports[0])
            if proof.get('registry_ready', False) is not registry_ready:
                raise ValueError('Installed report registry intent differs')
            if proof['target'] != target:
                raise ValueError('Installed report target differs')
            if channel == 'npm':
                if (proof['source_commit'] != source['commit'] or proof['run_id'] != args.run_id
                        or proof['run_attempt'] != args.run_attempt or proof['route'] != routes[route]
                        or proof['tarball_sha256'] != sums['archway-architecture-cli-0.1.0.tgz']):
                    raise ValueError('npm report source/run/route/tarball identity differs')
                phases = ['cached'] if route == 'cache' else ['installed', 'relocated']
                if [c['phase'] for c in proof['cases']] != phases:
                    raise ValueError('npm installed/relocated/cache phases missing')
                for case in proof['cases']:
                    if ([case[k] for k in ('help', 'version', 'init')] != [0, 0, 0]
                            or [(c['case'], c['exit']) for c in case['analysis']] != CASES):
                        raise ValueError('npm route checks are incomplete or failed')
                    validate_npm_termination(case, target, route, proof["node"], proof["npm"])
                    validate_npm(case, route)
                    validate_npm_runtime(case, target, root / channel / name)
            else:
                if (proof['source'] != source or proof['transport'] != transport
                        or proof['file_set_sha256'] != transport['file_set_sha256']
                        or set(proof['phases']) != {'installed', 'poisoned_source_snapshot'}):
                    raise ValueError('pub report source/transport/file-set identity differs')
                for phase in proof['phases'].values():
                    commands = phase['commands']
                    if ([c['arguments'] for c in commands] !=
                            [['--help'], ['--version'], ['init', '--template', 'mixed']]
                            or [c['exit'] for c in commands] != [0, 0, 0]):
                        raise ValueError('pub installed/snapshot checks are incomplete or failed')
                validate_pub(proof, root / channel / name, target, Path.cwd())
    files = []
    for path in sorted(root.rglob('*')):
        if path.is_dir() and not path.is_symlink():
            continue
        ordinary(path, MAX_TOTAL)
        name = path.relative_to(root).as_posix()
        if not canonical(name):
            raise ValueError('Invalid installed-route evidence path')
        files.append((path, name))
    if sum(p.stat().st_size for p, _ in files) > MAX_TOTAL:
        raise ValueError('Installed-route evidence exceeds bound')
    return files


def finalize(args):
    if getattr(args, 'registry_ready', False) and args.installed_evidence is None:
        raise ValueError('Registry-ready finalization requires installed receipts')
    release, reports, output = (p.absolute() for p in
                               (args.release_directory, args.reports, args.output))
    if os.path.lexists(output):
        raise ValueError('Final output already exists')
    source = source_identity(Path.cwd())
    if source['commit'] != args.expected_commit:
        raise ValueError('Source differs from expected commit')
    expected_names = {'archway-0.1.0-' + t + ('.zip' if t == 'windows-x64' else '.tar.gz')
                      for t in TARGETS} | {'archway-architecture-cli-0.1.0.tgz', 'QUICKSTART.txt', EVIDENCE}
    ordinary(release / 'SHA256SUMS', MAX_JSON)
    sums = {}
    for line in (release / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ')
        if name not in expected_names or name in sums:
            raise ValueError('Unexpected checksum entry')
        ordinary(release / name, MAX_TOTAL)
        if _sha256(release / name) != digest:
            raise ValueError('Producer asset checksum differs')
        sums[name] = digest
    if set(sums) != expected_names or {p.name for p in release.iterdir()} != expected_names | {'SHA256SUMS'}:
        raise ValueError('Expected exactly seven producer release files')
    installed_files = (installed_receipts(args.installed_evidence.absolute(), source, sums, args)
                       if args.installed_evidence is not None else [])
    receipts = {}
    installers = {}
    installer_hashes = {}
    for target in TARGETS:
        path = one(reports / target, 'report.json')
        proof = read_record(path)
        name = 'archway-0.1.0-' + target + ('.zip' if target == 'windows-x64' else '.tar.gz')
        if (proof['source'] != source or proof['target'] != target
                or proof['ci_host_verified'] is not True or proof['archive'] != name
                or proof['archive_sha256'] != sums[name] or proof['native_commands'] != COMMANDS
                or [(c['case'], c['exit']) for c in proof['typescript']] != CASES):
            raise ValueError('Native receipt does not establish required archive checks')
        validate_native(proof, path, reports / target, source)
        manifest, files = archive_manifest(release / name, target == 'windows-x64')
        installers[target] = validate_installer(proof, path.parent, files['manifest.json']['sha256'])
        installer_hashes[target] = proof['installer']['artifact']['sha256']
        validate_source(proof, path, manifest, Path.cwd())
        receipts[target] = path
    with zipfile.ZipFile(release / EVIDENCE) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(n.startswith('native-smoke/') for n in names):
            raise ValueError('Duplicate or already-finalized evidence')
        info = archive.getinfo('release-packaging.json')
        if info.file_size > MAX_JSON or json.loads(archive.read(info))['source'] != source:
            raise ValueError('Producer evidence source differs')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archway-final-', dir=output.parent) as temp:
        stage = Path(temp) / 'final'
        shutil.copytree(release, stage)
        for target, installer in installers.items():
            shutil.copyfile(installer, stage / installer.name)
            if _sha256(stage / installer.name) != installer_hashes[target]:
                raise ValueError('Tested installer changed during finalization')
        with zipfile.ZipFile(stage / EVIDENCE, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
            for path, name in installed_files:
                archive.write(path, 'installed-routes/' + name)
            for target, receipt in receipts.items():
                archive.write(receipt, f'native-smoke/{target}.json')
                native_files = [p for p in (reports / target).rglob('*')
                                if not (p.is_dir() and not p.is_symlink()) and p != installers[target]]
                if sum(p.stat().st_size for p in native_files) > MAX_TOTAL:
                    raise ValueError('Native receipt archive exceeds bound')
                for path in native_files:
                    if path.suffix.lower() in ('.deb', '.pkg', '.exe'):
                        raise ValueError('Unexpected installer binary in native evidence: ' + path.name)
                    ordinary(path, MAX_TOTAL)
                    name = path.relative_to(reports / target).as_posix()
                    if not canonical(name):
                        raise ValueError('Native evidence path differs')
                    archive.write(path, f'native-smoke/{target}/' + name)
            archive.writestr('native-smoke/acceptance.json', json.dumps({
                'source': source, 'original_producer_sha256': sums,
                'scope': 'Matching three-host native archive receipts; payload archives unchanged',
                'workflow': {k: os.environ.get(k) for k in
                             ('GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')}},
                indent=2, sort_keys=True) + '\n')
        for name, digest in sums.items():
            if name != EVIDENCE and _sha256(stage / name) != digest:
                raise ValueError('Tested release payload changed during finalization')
        (stage / 'SHA256SUMS').write_text(''.join(
            f'{_sha256(stage / name)}  {name}\n' for name in sorted(expected_names | {p.name for p in installers.values()})), encoding='utf-8')
        if source_identity(Path.cwd()) != source or os.path.lexists(output):
            raise ValueError('Source or output changed during finalization')
        stage.rename(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('release-directory', 'reports', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--installed-evidence', type=Path)
    parser.add_argument('--registry-ready', action='store_true')
    for name in ('run-id', 'run-attempt', 'expected-pub-transport-json'):
        parser.add_argument('--' + name)
    try:
        finalize(parser.parse_args())
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        sys.exit(f'Release finalization refused: {error}')
