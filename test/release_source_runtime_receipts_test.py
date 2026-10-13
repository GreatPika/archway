"""Expanded receipt boundaries; synthetic fixtures are not actual test execution."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
from installation_artifact import source_identity
from release_source_receipts import validate_source
from release_npm_runtime_receipts import validate_npm_runtime
from release_receipt_fixtures import native_fixture
from release_source_runtime_fixtures import (archive_fixture, source_fixture, npm_runtime_fixture,
                                             source_checkout_fixture)


class ExpandedReceipts(unittest.TestCase):
    def test_source_snapshot_finishes_automatic_maintenance_before_returning(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            baseline = base / 'baseline'
            baseline.mkdir()
            (baseline / 'tracked.txt').write_bytes(b'Synthetic tracked baseline\n')
            subprocess.run(['git', '-C', str(baseline), 'init', '--quiet', '--template='], check=True)
            subprocess.run(['git', '-C', str(baseline), 'add', '.'], check=True)
            trace = base / 'git-trace.json'
            # Force real maintenance work, including an inherited request to detach.
            config = {'maintenance.auto': 'true', 'maintenance.autoDetach': 'true',
                      'maintenance.commit-graph.enabled': 'true',
                      'maintenance.commit-graph.auto': '-1'}
            env = {'GIT_TRACE2_EVENT': str(trace), 'GIT_CONFIG_COUNT': str(len(config))}
            for index, (key, value) in enumerate(config.items()):
                env[f'GIT_CONFIG_KEY_{index}'] = key
                env[f'GIT_CONFIG_VALUE_{index}'] = value
            with patch.dict(os.environ, env):
                source_checkout_fixture(baseline, base / 'snapshot')
            events = [json.loads(line) for line in trace.read_text().splitlines()]
            maintenance = [event for event in events if event['event'] == 'child_start'
                           and event['argv'][1:3] == ['maintenance', 'run']]
            self.assertEqual(len(maintenance), 1)
            child = maintenance[0]
            self.assertIn('--no-detach', child['argv'])
            self.assertNotIn('--detach', child['argv'])
            graph = next(event for event in events if event['event'] == 'child_start'
                         and event['argv'][1:3] == ['commit-graph', 'write'])
            graph_exit = next(index for index, event in enumerate(events)
                              if event['event'] == 'child_exit' and event['sid'] == graph['sid']
                              and event['child_id'] == graph['child_id'])
            child_exit = next(index for index, event in enumerate(events)
                              if event['event'] == 'child_exit' and event['sid'] == child['sid']
                              and event['child_id'] == child['child_id'])
            commit_exit = next(index for index, event in enumerate(events)
                               if event['event'] == 'exit' and event['sid'] == child['sid'])
            self.assertEqual(events[child_exit]['code'], 0)
            self.assertEqual(events[graph_exit]['code'], 0)
            self.assertLess(graph_exit, child_exit)
            self.assertLess(child_exit, commit_exit)

    def test_source_snapshot_rejects_symlinked_ancestor_before_copying_external_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            working = base / 'working'
            directory = working / 'nested'
            directory.mkdir(parents=True)
            (directory / 'tracked.txt').write_bytes(b'Tracked fixture\n')
            subprocess.run(['git', '-C', str(working), 'init', '--quiet', '--template='], check=True)
            subprocess.run(['git', '-C', str(working), 'add', '.'], check=True)
            external = base / 'external'
            directory.rename(external)
            (external / 'tracked.txt').write_bytes(b'External bytes must not be copied\n')
            directory.symlink_to(external, target_is_directory=True)
            snapshot = base / 'snapshot'
            with self.assertRaisesRegex(ValueError, 'symlinked source ancestor'):
                source_checkout_fixture(working, snapshot)
            self.assertFalse((snapshot / 'nested/tracked.txt').exists())

    def test_source_snapshot_preserves_uncommitted_tracked_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            baseline = base / 'baseline'
            baseline.mkdir()
            for name in ('pubspec.lock', 'assets/typescript/package-lock.json',
                         'test/owned-source.dart', 'owned-deletion.txt'):
                entry = baseline / name
                entry.parent.mkdir(parents=True, exist_ok=True)
                entry.write_bytes(b'Synthetic tracked baseline\n')
            subprocess.run(['git', '-C', str(baseline), 'init', '--quiet', '--template='], check=True)
            subprocess.run(['git', '-C', str(baseline), 'add', '.'], check=True)
            working = source_checkout_fixture(baseline, base / 'working')
            path = working / 'test/owned-source.dart'
            changed = path.read_bytes() + b'\n// Uncommitted synthetic source fixture.\n'
            path.write_bytes(changed)
            (working / 'owned-deletion.txt').unlink()
            staged = working / 'test/staged-current-file.txt'
            staged.write_bytes(b'Synthetic staged addition\n')
            subprocess.run(['git', '-C', str(working), 'add', str(staged)], check=True)
            untracked = working / 'untracked-fixture.txt'
            untracked.write_bytes(b'Untracked files are outside the source fixture\n')
            if os.name != 'nt':
                path.chmod(0o755)
                external = base / 'external.txt'
                external.write_bytes(b'External bytes must not be copied\n')
                link = working / 'test/external-link'
                link.symlink_to(external)
                subprocess.run(['git', '-C', str(working), 'add', str(link)], check=True)
            before = subprocess.check_output(['git', '-C', str(working), 'status', '--porcelain'])
            self.assertIn(b'test/owned-source.dart', before)
            snapshot = source_checkout_fixture(working, base / 'snapshot')
            self.assertEqual((snapshot / path.relative_to(working)).read_bytes(), changed)
            self.assertEqual(subprocess.check_output(['git', '-C', str(snapshot), 'show',
                'HEAD:test/owned-source.dart']), changed)
            self.assertFalse((snapshot / 'owned-deletion.txt').exists())
            self.assertEqual((snapshot / staged.relative_to(working)).read_bytes(), staged.read_bytes())
            self.assertFalse((snapshot / untracked.name).exists())
            if os.name != 'nt':
                self.assertEqual((snapshot / path.relative_to(working)).stat().st_mode & 0o777, 0o755)
                copied_link = snapshot / link.relative_to(working)
                self.assertTrue(copied_link.is_symlink())
                self.assertEqual(os.readlink(copied_link), str(external))
            self.assertNotEqual(source_identity(snapshot)['tree'],
                subprocess.check_output(['git', '-C', str(working), 'rev-parse', 'HEAD^{tree}'], text=True).strip())
            self.assertEqual(subprocess.check_output(['git', '-C', str(working), 'status', '--porcelain']), before)

    def test_npm_commands_runtime_identity_and_failures_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proof = npm_runtime_fixture(root, 'linux-x64')
            validate_npm_runtime(proof, 'linux-x64', root)
            mutations = [lambda p: p['command_controls'].pop(),
                         lambda p: p['command_controls'][3].update(arguments=['rewritten argv']),
                         lambda p: p['command_controls'][0].update(native_parity=False),
                         lambda p: p['runtime_controls']['wrong_node'].update(executable_sha256='0'*64),
                         lambda p: p['runtime_controls']['cases'][1].update(exit=0),
                         lambda p: p['runtime_controls']['cases'][0].update(invocation='native-only')]
            for index, mutation in enumerate(mutations):
                changed = copy.deepcopy(proof)
                mutation(changed)
                with self.subTest(index=index), self.assertRaises(ValueError):
                    validate_npm_runtime(changed, 'linux-x64', root)

    def test_source_inventory_assets_argv_results_and_fixture_skips_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = source_checkout_fixture(ROOT, root / 'source')
            identity = source_identity(source)
            archive = archive_fixture(root, 'linux-x64', identity)
            proof = {'source':identity,'target':'linux-x64',**native_fixture(root,'linux-x64',identity)}
            proof['acceptance']['source_suite'] = source_fixture(root,'linux-x64',identity,source,archive,
                proof['acceptance']['fixtures']['manifest'])
            report = root/'report.json'
            validate_source(proof, report, archive, source)
            mutations = [lambda p: p['acceptance'].pop('source_suite'),
                         lambda p: p['acceptance']['source_suite']['source'].update(commit='0'*40),
                         lambda p: p['acceptance']['source_suite']['assets'].clear(),
                         lambda p: p['acceptance']['source_suite']['execution'].update(command=['/wrong/dart','test']),
                         lambda p: p['acceptance']['source_suite']['execution'].update(timed_out=True),
                         lambda p: p['acceptance']['source_suite']['tests'].update(passed=0)]
            for index, mutation in enumerate(mutations):
                changed=copy.deepcopy(proof)
                mutation(changed)
                with self.subTest(index=index), self.assertRaises((ValueError,KeyError)):
                    validate_source(changed,report,archive,source)
            for token in ('test/', './test', '--reporter=json/'):
                changed = copy.deepcopy(proof)
                execution = changed['acceptance']['source_suite']['execution']
                execution['command'][2 if token.startswith('--') else 1] = token
                (root/'acceptance/source-tests.json').write_text(json.dumps(execution))
                with self.subTest(token=token), self.assertRaises(ValueError):
                    validate_source(changed, report, archive, source)
            (root/'acceptance/source-tests.json').write_text(
                json.dumps(proof['acceptance']['source_suite']['execution']))
            changed=copy.deepcopy(proof)
            execution=changed['acceptance']['source_suite']['execution']
            stdout=root/'acceptance'/execution['stdout']
            events=[json.loads(line) for line in stdout.read_text().splitlines()]
            suite_id=next(e['suite']['id'] for e in events if e['type']=='suite' and e['suite']['path']=='test/dart_flutter_test.dart')
            next(e for e in events if e['type']=='testDone' and e['testID']==suite_id)['skipped']=True
            stdout.write_text('\n'.join(json.dumps(e) for e in events))
            execution['stdout_sha256']=hashlib.sha256(stdout.read_bytes()).hexdigest()
            (root/'acceptance/source-tests.json').write_text(json.dumps(execution))
            with self.assertRaisesRegex(ValueError,'Unapproved source test skip'):
                validate_source(changed,report,archive,source)


if __name__=='__main__':
    unittest.main()
