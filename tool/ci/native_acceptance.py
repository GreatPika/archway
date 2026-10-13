"""Complete final-archive process acceptance, with durable per-suite evidence.

The caller verifies and extracts the release archive. Every process receives
that executable; destructive fault suites stage their own byte-for-byte copies.
Fixture preparation is separate and must finish before this runner starts.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from installation_artifact import source_identity
from native_source_acceptance import run_source_tests

FIXTURE_KEYS = ('dart_sdk', 'wrong_node', 'pub_fixture', 'git_fixture',
                'flutter_sdk', 'flutter_fixture')
SUITE_TIMEOUT = 600  # Includes the genuine 120-second production deadline.


class SuiteExitFailure(ValueError):
    """A completed process suite failed; its evidence is already durable."""

    def __init__(self, proof, message):
        super().__init__(message)
        self.proof = proof


def read_fixtures(path):
    data = Path(path).read_bytes()
    manifest = json.loads(data)
    fixtures = {}
    for key in FIXTURE_KEYS:
        value = manifest.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ValueError(f'Acceptance fixture {key} must be an absolute path')
        selected = Path(value)
        if not (selected.is_file() if key == 'wrong_node' else selected.is_dir()):
            raise ValueError(f'Acceptance fixture {key} is missing: {selected}')
        fixtures[key] = selected.resolve()
    environment = manifest.get('environment', {})
    if not isinstance(environment, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()):
        raise ValueError('Acceptance fixture environment must contain string values')
    fixtures['environment'] = environment
    return fixtures, {'sha256': hashlib.sha256(data).hexdigest(), 'manifest': manifest}


def suite_commands(repository, executable, node, fixtures, output, *, python=None):
    sdk = fixtures['dart_sdk']
    arguments = [
        ('plan_query', []), ('cli', []), ('catalogue_export', []),
        ('check', [node]), ('dart_check', [sdk, node, '--existing-installation']),
        ('physical_path', [sdk, node]),
        ('alias_wire', [node]), ('alias_hop_recheck', [node]),
        ('alias_trace_gap', [node]), ('dart_resource', [sdk]),
        ('runtime', [node]),
        ('runtime_request', [node, output / 'runtime-request-coverage.json']),
        ('runtime_preflight', [node, fixtures['wrong_node'], sdk]),
        ('native_asset', []), ('native_abi', []), ('native_fault', []),
        ('package_provenance', [repository, fixtures['pub_fixture'],
                                fixtures['git_fixture'], output / 'package-provenance']),
        ('dart_flutter', [fixtures['flutter_sdk'], fixtures['flutter_fixture']]),
    ]
    return [(name, [python or sys.executable, str(repository / 'test' / (name + '_process_smoke.py')),
                    str(executable), *map(str, args)]) for name, args in arguments]


def execute_suite(name, command, repository, environment, output):
    stdout = output / (name + '.stdout.log')
    stderr = output / (name + '.stderr.log')
    started = time.monotonic()
    # Files retain partial evidence on timeout instead of losing buffered output.
    timed_out = False
    with stdout.open('xb') as out, stderr.open('xb') as err:
        try:
            result = subprocess.run(command, cwd=repository, env=environment,
                                    stdout=out, stderr=err, timeout=SUITE_TIMEOUT)
            exit_code = result.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            exit_code = None
    proof = {'suite': name, 'command': command, 'exit_code': exit_code,
             'timed_out': timed_out,
             'elapsed_seconds': round(time.monotonic() - started, 3),
             'timeout_seconds': SUITE_TIMEOUT,
             'stdout': stdout.name, 'stderr': stderr.name,
             'stdout_sha256': hashlib.sha256(stdout.read_bytes()).hexdigest(),
             'stderr_sha256': hashlib.sha256(stderr.read_bytes()).hexdigest()}
    (output / (name + '.json')).write_text(json.dumps(proof, indent=2) + '\n')
    if timed_out:
        raise ValueError(f'Native acceptance suite {name} timed out after {SUITE_TIMEOUT} seconds; '
                         f'see {stdout} and {stderr}')
    if exit_code:
        raise SuiteExitFailure(proof, f'Native acceptance suite {name} failed with exit {exit_code}; '
                         f'see {stderr}')
    return proof


def run_acceptance(repository, executable, node, fixture_path, output, verify_installation):
    harness_source = source_identity(repository)
    fixtures, provenance = read_fixtures(fixture_path)
    output.mkdir(parents=True, exist_ok=False)
    environment = {**os.environ, **fixtures['environment']}
    environment['PATH'] = os.pathsep.join([str(fixtures['dart_sdk'] / 'bin'),
        str(node.parent), environment.get('PATH', '')])
    results = []
    failures = []

    def record_failure(name, error):
        failures.append({'suite': name, 'error': str(error)})
        (output / 'failures.json').write_text(json.dumps(failures, indent=2) + '\n')
        print(str(error), file=sys.stderr, flush=True)

    for name, command in suite_commands(repository, executable, node, fixtures, output):
        print(f'Final archive acceptance: {name}', flush=True)
        verify_installation()
        # Each process suite owns its project fixtures; fault suites copy the
        # installation before mutation. Only completed nonzero exits can be
        # collected. Timeouts may leave descendants and must stop immediately.
        try:
            results.append(execute_suite(name, command, repository, environment, output))
        except SuiteExitFailure as error:
            results.append(error.proof)
            record_failure(name, error)
        finally:
            # An altered shared archive is a broken prerequisite, not an
            # independent test failure. Never start another suite after it.
            verify_installation()
    print('Final archive acceptance: full source Dart suite', flush=True)
    try:
        source_suite = run_source_tests(repository, executable, fixtures, environment, output, execute_suite)
    except Exception as error:
        # The source gate owns a fresh snapshot. Its internal preparation still
        # fails fast; there is no dependent work to run after any source error.
        record_failure('source', error)
    verify_installation()
    if source_identity(repository) != harness_source:
        raise ValueError('Acceptance test sources changed during execution')
    if failures:
        raise ValueError('Native acceptance failed: ' + '; '.join(
            entry['suite'] + ': ' + entry['error'] for entry in failures))
    return {'scope': 'Complete applicable final native archive process suites',
            'source': harness_source, 'source_root': str(repository.resolve()),
            'python': sys.executable, 'node_path': str(node.resolve()), 'output_root': str(output.resolve()),
            'fixtures': provenance, 'suites': results, 'source_suite': source_suite}
