"""Offline intent/identity tests; no executable package or registry acceptance."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import npm_local_install_probe as npm
import pub_snapshot_probe as pub


class RegistryConsumers(unittest.TestCase):
    def test_npm_requires_explicit_matching_intent(self):
        with tempfile.TemporaryDirectory() as temporary:
            packed = Path(temporary)
            archive = packed / 'archway.tgz'
            archive.write_bytes(b'inert synthetic archive')
            evidence = {'filename': archive.name, 'compressed_bytes': archive.stat().st_size,
                        'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                        'manifest_sha256': 'a' * 64, 'targets': sorted(npm.TARGETS)}
            record = packed / 'packed-evidence.json'
            record.write_text(json.dumps(evidence))
            self.assertEqual(npm.verified_tarball(packed)[0], archive)
            with self.assertRaisesRegex(ValueError, 'registry intent'):
                npm.verified_tarball(packed, registry_ready=True)
            evidence['registry_ready'] = True
            record.write_text(json.dumps(evidence))
            self.assertEqual(npm.verified_tarball(packed, registry_ready=True)[0], archive)
            with self.assertRaisesRegex(ValueError, 'registry intent'):
                npm.verified_tarball(packed)
            evidence['registry_ready'] = 1
            record.write_text(json.dumps(evidence))
            with self.assertRaisesRegex(ValueError, 'registry intent'):
                npm.verified_tarball(packed, registry_ready=True)

    def test_npm_probe_forwards_intent_before_running_any_command(self):
        for intent in (False, True):
            with patch.object(npm, 'verified_tarball', side_effect=ValueError('stop')) as verify:
                with self.assertRaisesRegex(ValueError, 'stop'):
                    npm.probe(Path('packed'), 'linux-x64', registry_ready=intent)
                verify.assert_called_once_with(Path('packed'), registry_ready=intent)

    def test_pub_candidate_refuses_untransported_stage_before_execution(self):
        args = SimpleNamespace(registry_ready=True, transport_archive=None)
        with self.assertRaisesRegex(ValueError, 'requires authenticated archive transport'):
            pub.probe(args)

    def test_pub_forwards_intent_to_expected_transport_before_execution(self):
        for intent in (False, True):
            args = SimpleNamespace(registry_ready=intent, transport_archive=Path('archive'),
                                   expected_transport_json='{}', expected_source='a' * 40,
                                   run_id='123', run_attempt='1')
            with patch.object(pub, 'expectation', side_effect=ValueError('stop')) as expected:
                with self.assertRaisesRegex(ValueError, 'stop'):
                    pub.probe(args)
                expected.assert_called_once_with('{}', 'a' * 40, '123', '1', registry_ready=intent)

    def test_pub_consumes_authenticated_archive_with_matching_intent(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            args = SimpleNamespace(registry_ready=True, transport_archive=base / 'archive',
                expected_transport_json='{}', expected_source='a' * 40, run_id='123', run_attempt='1',
                target='linux-x64', output=base / 'output', dart=base / 'dart', source=base / 'source')
            transport = {'file_set_sha256': 'b' * 64}
            with patch.object(pub, 'expectation', return_value=transport), \
                 patch.object(pub, 'actual_host', return_value={}), \
                 patch.object(pub.shutil, 'which', return_value='/inert/git'), \
                 patch.object(pub, 'environment', return_value={}), \
                 patch.object(pub, 'run', return_value=SimpleNamespace(
                     stdout=b'Dart SDK version: 3.13.3 fixture', stderr=b'')), \
                 patch.object(pub, 'read_transport', side_effect=ValueError('stop before activation')) as read:
                with self.assertRaisesRegex(ValueError, 'stop before activation'):
                    pub.probe(args)
                read.assert_called_once_with(args.transport_archive, transport, args.source,
                    args.output / 'received-stage', registry_ready=True)


    def test_npm_report_marks_only_candidate_intent_without_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            node = base / 'node'
            (base / ('npm.cmd' if npm.os.name == 'nt' else 'npm')).touch()
            for intent in (False, True):
                with patch.object(npm, 'verified_tarball', return_value=(base / 'inert.tgz', {'sha256': 'a' * 64})), \
                     patch.object(npm.platform, 'system', return_value='Linux'), \
                     patch.object(npm.platform, 'machine', return_value='x86_64'), \
                     patch.object(npm.shutil, 'which', side_effect=lambda name, **kw: str(node) if name == 'node' else None), \
                     patch.object(npm, 'checked', side_effect=[SimpleNamespace(stdout=b'["v24.21.0","linux","x64"]'),
                                                              SimpleNamespace(stdout=b'11.19.0')]), \
                     patch.object(npm, 'exercise_cache', return_value={'phase': 'cached'}):
                    report = npm.probe(base, 'linux-x64', route='cache', registry_ready=intent)
                self.assertEqual(report.get('registry_ready', False), intent)
                self.assertEqual('registry_ready' in report, intent)
                self.assertEqual(report['tarball_sha256'], 'a' * 64)


if __name__ == '__main__':
    unittest.main()
