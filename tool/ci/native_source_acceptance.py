"""Full source tests using verified release assets and genuine prepared fixtures."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from installation_artifact import source_identity


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_skip(target, path, name, reason=None):
    # Existing explicit source-fixture OS guards, never optional dependencies.
    windows = {
        ('test/windows_native_probe_test.dart', 'Windows x64 CLI init creates both files in a fresh root'),
        ('test/physical_paths_test.dart', 'Windows root canonicalization follows an absolute directory symbolic link'),
        ('test/physical_paths_test.dart', 'Windows root canonicalization follows a local directory junction'),
    }
    linux = {
        ('test/dart_adversarial_test.dart', 'unreadable selected analysis options cannot become an absent clean configuration'),
        *[('test/dart_adversarial_test.dart', f'a stable {kind} entry outside scope does not change inventory identity')
          for kind in ('ordinary', 'fifo', 'socket')],
        ('test/input_mutations_test.dart', 'an unreadable selected directory is a corpus gap, not an empty clean region'),
        *[('test/physical_compilers_test.dart', f'{language} hardlinks retain pathname owners and exact boundary decisions')
          for language in ('dart', 'typescript')],
        ('test/physical_paths_test.dart', 'an exact NFC scope cannot hide a differently normalized physical entry'),
    }
    posix = {
        ('test/physical_paths_test.dart', 'unrepresentable and NFC-colliding entries are incomplete without a global failure'),
        ('test/physical_paths_test.dart', 'a literal POSIX backslash filename cannot become a clean absent portable path'),
    }
    entry = (path, name)
    if (target == 'windows-x64' and entry == ('test/catalogue_export_test.dart',
            'overwrite rejects a FIFO with a live reader before sending content')
            and reason == 'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.'):
        return True
    if (entry == ('test/physical_paths_test.dart',
                  'case-insensitive source lookup does not relax exact scope spelling')
            and reason == 'Requires a case-insensitive filesystem.'):
        return True
    return ((target != 'windows-x64' and entry in windows)
            or (target != 'linux-x64' and entry in linux)
            or (target == 'windows-x64' and entry in posix))


def summarize_tests(events, expected_files, target):
    suites, tests, finished, skip_reasons = {}, {}, set(), {}
    suite_paths = {}
    skipped, passed, completed = [], 0, False
    accounted_suites = set()
    for event in events:
        kind = event['type']
        if kind == 'suite':
            suite = event['suite']
            suites[suite['id']] = suite['path'].replace('\\', '/')
            suite_paths[suite['id']] = suite['path']
        elif kind == 'testStart':
            tests[event['test']['id']] = event['test']
        elif kind == 'print' and event.get('messageType') == 'skip':
            skip_reasons[event['testID']] = event['message']
        elif kind == 'testDone':
            if event['result'] != 'success' or event['testID'] in finished:
                raise ValueError('Failed or duplicate source test result')
            finished.add(event['testID'])
            test = tests[event['testID']]
            path = suites[test['suiteID']]
            if event.get('hidden'):
                # Dart uses the original host path spelling in loader names.
                # Keep exact loader identity separate from portable inventory.
                loading = (test['name'] == 'loading ' + suite_paths[test['suiteID']]
                           and test.get('groupIDs') == [] and test.get('url') is None)
                hook = test['name'] in ('(setUpAll)', '(tearDownAll)')
                if event['skipped'] or not (loading or hook):
                    raise ValueError('Unexpected hidden source test result')
                continue
            accounted_suites.add(test['suiteID'])
            if event['skipped']:
                reason = test['metadata'].get('skipReason') or skip_reasons.get(event['testID'])
                if not expected_skip(target, path, test['name'], reason):
                    raise ValueError(f'Unapproved source test skip: {path}: {test["name"]}')
                skipped.append({'file': path, 'name': test['name'],
                                'reason': reason,
                                'applicability': 'Existing explicit source-fixture OS/filesystem guard'})
            else:
                passed += 1
        elif kind == 'done':
            if completed or event['success'] is not True:
                raise ValueError('Source test suite did not succeed')
            completed = True
    if (not completed or set(suites.values()) != expected_files
            or set(tests) != finished or not tests or accounted_suites != set(suites)):
        raise ValueError('Incomplete source test suite inventory or terminal results')
    return {'suites': sorted(expected_files), 'passed': passed, 'skipped': skipped}


def source_test_environment(environment, parent):
    temporary = parent / 'test-tmp'
    temporary.mkdir()
    canonical = str(temporary.resolve(strict=True))
    return {**environment, 'ARCHWAY_TEST_PYTHON': str(Path(sys.executable).resolve(strict=True)),
            **{key: canonical for key in ('TMPDIR', 'TMP', 'TEMP', 'RUNNER_TEMP')}}


def run_source_tests(repository, executable, fixtures, environment, output, execute):
    identity = source_identity(repository)
    target = executable.parent.name
    library = {'linux-x64': 'libarchway_io.so', 'macos-arm64': 'libarchway_io.dylib',
               'windows-x64': 'archway_io.dll'}[target]
    bundle = executable.parents[2]
    dart = fixtures['dart_sdk'] / 'bin' / ('dart.exe' if target == 'windows-x64' else 'dart')
    environment = {**environment, 'ARCHWAY_PUB_GIT_FIXTURE': str(fixtures['git_fixture']),
                   'ARCHWAY_FLUTTER_FIXTURE': str(fixtures['flutter_fixture'])}
    for fixture in ('git_fixture', 'flutter_fixture'):
        for name in ('pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json'):
            if not (fixtures[fixture] / name).is_file():
                raise ValueError(f'Missing mandatory source fixture: {fixture}/{name}')
    tracked = subprocess.run(['git', '-C', str(repository), 'ls-files', '-z'],
                             check=True, capture_output=True, timeout=30).stdout.decode().split('\0')
    tracked = sorted(name for name in tracked if name)
    expected_tests = {name for name in tracked if name.startswith('test/') and name.endswith('_test.dart')}
    with tempfile.TemporaryDirectory(prefix='archway-source-suite-') as temp:
        environment = source_test_environment(environment, Path(temp))
        source = Path(temp).resolve() / 'source'
        source.mkdir()
        snapshot = {}
        for name in tracked:
            original = repository / name
            if not original.is_file() or original.is_symlink():
                raise ValueError(f'Source snapshot requires an ordinary tracked file: {name}')
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, destination)
            snapshot[name] = sha(original)
            if sha(destination) != snapshot[name]:
                raise ValueError('Source snapshot bytes changed during copying')
        inventory = output / 'source-files.json'
        inventory.write_text(json.dumps(snapshot, sort_keys=True, indent=2) + '\n')
        bridge = f'native/{target}/{library}'
        assets = {bridge: sha(bundle / bridge)}
        (source / bridge).parent.mkdir(parents=True)
        shutil.copy2(bundle / bridge, source / bridge)
        vendor = 'assets/typescript/vendor'
        shutil.copytree(bundle / vendor, source / vendor)
        for path in (source / vendor).rglob('*'):
            if path.is_file():
                relative = path.relative_to(source).as_posix()
                assets[relative] = sha(path)
                if assets[relative] != sha(bundle / relative):
                    raise ValueError('Source-suite asset differs from verified archive')
        preparation = execute('source-pub-get', [str(dart), '--suppress-analytics',
            'pub', 'get', '--enforce-lockfile'], source, environment, output)
        if sha(source / 'pubspec.lock') != snapshot['pubspec.lock']:
            raise ValueError('Source dependency preparation changed the exact lock')
        execution = execute('source-tests', [str(dart), 'test', '--reporter=json'],
                            source, environment, output)
        events = [json.loads(line) for line in (output / execution['stdout']).read_text().splitlines()]
        summary = summarize_tests(events, expected_tests, target)
        for name, digest in {**snapshot, **assets}.items():
            if sha(source / name) != digest:
                raise ValueError(f'Source tests changed snapshot/installation bytes: {name}')
        if source_identity(repository) != identity:
            raise ValueError('Original tracked sources changed during source tests')
        return {'source': identity, 'snapshot_root': str(source), 'dart': str(dart),
                'target': target, 'snapshot_manifest': inventory.name,
                'snapshot_manifest_sha256': sha(inventory), 'assets': assets,
                'preparation': preparation, 'execution': execution, 'tests': summary}
