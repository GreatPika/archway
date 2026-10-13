"""Offline receipt binding; synthetic records do not certify installed packages."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import finalize_release_evidence as finalizer


class RegistryFinalizer(unittest.TestCase):
    def test_candidate_cannot_finalize_without_installed_receipts(self):
        args = SimpleNamespace(registry_ready=True, installed_evidence=None)
        with self.assertRaisesRegex(ValueError, 'requires installed receipts'):
            finalizer.finalize(args)

    def test_candidate_receipts_require_matching_intent_and_upload_identity(self):
        source = {'commit': 'a' * 40, 'tree': 'b' * 40, 'lockfile_sha256': {
            'pubspec.lock': 'c' * 64, 'assets/typescript/package-lock.json': 'd' * 64}}
        transport = {'schema_version': 2, 'registry_ready': True, 'source': source,
            'file_set_sha256': 'e' * 64, 'archive': {'sha256': 'f' * 64, 'size': 10},
            'run_id': '123', 'run_attempt': '1', 'upload_archive': {
                'sha256': '1' * 64, 'size': 9, 'unpacked_bytes': 8, 'files': 1}}
        args = SimpleNamespace(registry_ready=True, run_id='123', run_attempt='1',
                               expected_pub_transport_json=json.dumps(transport))
        sums = {'archway-architecture-cli-0.1.0.tgz': '2' * 64}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = {}
            for target in finalizer.TARGETS:
                for route, label in [('local', 'local-devDependency'), ('global', 'global-prefix'),
                                     ('cache', 'npm-exec-cache')]:
                    path = root / 'npm' / f'npm-installed-{route}-{target}-123-1/report.json'
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps({'registry_ready': True, 'target': target,
                        'source_commit': source['commit'], 'run_id': '123', 'run_attempt': '1',
                        'route': label, 'tarball_sha256': sums['archway-architecture-cli-0.1.0.tgz'],
                        'node': [], 'npm': 'synthetic', 'cases': [{'phase': phase,
                            'help': 0, 'version': 0, 'init': 0,
                            'analysis': [{'case': case, 'exit': code} for case, code in finalizer.CASES]}
                            for phase in (['cached'] if route == 'cache' else ['installed', 'relocated'])]}))
                    paths['npm'] = path
                path = root / 'pub' / f'pub-installed-{target}-123-1/report.json'
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps({'registry_ready': True, 'target': target, 'source': source,
                    'transport': transport, 'file_set_sha256': transport['file_set_sha256'],
                    'phases': {phase: {'commands': [{'arguments': arguments, 'exit': 0}
                        for arguments in [['--help'], ['--version'], ['init', '--template', 'mixed']]]}
                        for phase in ['installed', 'poisoned_source_snapshot']}}))
                paths['pub'] = path
            with patch.object(finalizer, 'validate_pub'), patch.object(finalizer, 'validate_npm'), \
                 patch.object(finalizer, 'validate_npm_runtime'), patch.object(finalizer, 'validate_npm_termination'):
                self.assertEqual(len(finalizer.installed_receipts(root, source, sums, args)), 12)
                for channel, path in paths.items():
                    original = path.read_text()
                    for invalid in (False, 1, None):
                        changed = json.loads(original)
                        changed['registry_ready'] = invalid
                        path.write_text(json.dumps(changed))
                        with self.subTest(channel=channel, invalid=invalid), self.assertRaisesRegex(
                                ValueError, 'registry intent'):
                            finalizer.installed_receipts(root, source, sums, args)
                    path.write_text(original)
                changed = json.loads(paths['pub'].read_text())
                changed['transport']['upload_archive']['sha256'] = '3' * 64
                paths['pub'].write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'pub report source/transport'):
                    finalizer.installed_receipts(root, source, sums, args)
                args.registry_ready = False
                with self.assertRaisesRegex(ValueError, 'Invalid expected transport'):
                    finalizer.installed_receipts(root, source, sums, args)


if __name__ == '__main__':
    unittest.main()
