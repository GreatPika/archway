"""Synthetic receipt refusal tests; never native installer acceptance."""
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from release_installer_receipts import validate_installer
from native_installer_receipt_fixtures import installer_fixture
from release_receipt_fixtures import native_fixture


class InstallerReceipts(unittest.TestCase):
    def test_exact_installer_bytes_and_original_logs_are_bound(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            installer = installer_fixture(root, 'linux-x64', 'a' * 64)
            proof = {'target': 'linux-x64', 'source': {'commit':'f'*40}, **native_fixture(root, 'linux-x64', {}), 'installer': installer}
            path = validate_installer(proof, root, 'a' * 64)
            self.assertEqual(path.name, 'archway-0.1.0-linux-x64-unsigned.deb')
            original = copy.deepcopy(proof)
            proof['installer']['installed']['suites'][0]['exit_code'] = 1
            with self.assertRaises(ValueError):
                validate_installer(proof, root, 'a' * 64)
            proof = original
            path.write_bytes(b'changed installer')
            with self.assertRaises(ValueError):
                validate_installer(proof, root, 'a' * 64)

    def test_forged_receipt_fields_and_missing_original_output_are_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = {'target': 'linux-x64', 'source': {'commit':'f'*40}, **native_fixture(root, 'linux-x64', {}),
                        'installer': installer_fixture(root, 'linux-x64', 'a' * 64)}
            mutations = [
                lambda r: r.update(bundle_manifest_sha256='e'*64),
                lambda r: r['artifact'].update(name='test-only-old.deb'),
                lambda r: r.update(cases=r['cases'][:-1]),
                lambda r: r['old_fixture'].update(test_only=False),
                lambda r: r['old_fixture'].update(version='0.1.0'),
                lambda r: r['compiler'].update(sha256='invalid'),
                lambda r: r['installed'].update(manifest_sha256='e'*64),
                lambda r: r['installed'].update(runtime_controls=[]),
                lambda r: r['installed']['processes'][0].update(stdout_sha256='e'*64),
                lambda r: r['installed']['processes'][1].update(exit=1),
                lambda r: r['installed'].update(suites=[]),
            ]
            for mutate in mutations:
                proof = copy.deepcopy(original)
                mutate(proof['installer'])
                with self.assertRaises(ValueError):
                    validate_installer(proof, root, 'a' * 64)
            log = root / 'installer' / original['installer']['installed']['processes'][0]['stdout']
            log.write_bytes(b'changed original output')
            with self.assertRaises(ValueError):
                validate_installer(original, root, 'a' * 64)

    def test_schema_incomplete_original_json_cannot_pass_with_updated_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proof = {'target':'linux-x64','source':{'commit':'f'*40}, **native_fixture(root,'linux-x64',{}),
                     'installer':installer_fixture(root,'linux-x64','a'*64)}
            process = proof['installer']['installed']['processes'][3]
            data = b'{"command":"validate","exit_code":0}'
            (root/'installer'/process['stdout']).write_bytes(data)
            process['stdout_sha256'] = hashlib.sha256(data).hexdigest()
            with self.assertRaises(ValueError):
                validate_installer(proof,root,'a'*64)

    def test_all_targets_require_ordered_build_install_upgrade_remove_records(self):
        for target in ['linux-x64','macos-arm64','windows-x64']:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                original = {'target':target,'source':{'commit':'f'*40}, **native_fixture(root,target,{}),
                            'installer':installer_fixture(root,target,'a'*64)}
                validate_installer(original,root,'a'*64)
                for change in ['drop-build','swap-build','drop-upgrade','wrong-remove-tool','wrong-artifact','insert-reset']:
                    proof = copy.deepcopy(original)
                    phases = proof['installer']['commands']
                    if change == 'drop-build':
                        del phases[1]
                    elif change == 'swap-build':
                        phases[1],phases[2] = phases[2],phases[1]
                    elif change == 'drop-upgrade':
                        del phases[-2]
                    elif change == 'wrong-remove-tool':
                        phases[-1]['arguments'][0] = 'different-tool'
                    elif change == 'insert-reset':
                        reset = copy.deepcopy(phases[-1])
                        for stream in ('stdout','stderr'):
                            copied = 'reset-' + reset[stream]
                            (root/'installer'/copied).write_bytes((root/'installer'/reset[stream]).read_bytes())
                            reset[stream] = copied
                        phases.insert(len(phases)-2,reset)
                    else:
                        phases[-2]['arguments'] = [a.replace('0.1.0','0.9.9') for a in phases[-2]['arguments']]
                    with self.subTest(change=change), self.assertRaises(ValueError):
                        validate_installer(proof,root,'a'*64)

    def test_same_dpkg_root_reset_is_rejected_with_a_different_log_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proof = {'target':'linux-x64','source':{'commit':'f'*40}, **native_fixture(root,'linux-x64',{}),
                     'installer':installer_fixture(root,'linux-x64','a'*64)}
            records = proof['installer']['commands']
            reset = copy.deepcopy(records[-1])
            reset['arguments'][4] = '--log=/tmp/reset.log'
            for stream in ('stdout','stderr'):
                copied = 'other-log-reset-' + reset[stream]
                (root/'installer'/copied).write_bytes((root/'installer'/reset[stream]).read_bytes())
                reset[stream] = copied
            records.insert(len(records)-2,reset)
            with self.assertRaisesRegex(ValueError,'interrupted'):
                validate_installer(proof,root,'a'*64)
            reset['arguments'][3] = '--root=/fixture/other-system'
            validate_installer(proof,root,'a'*64)

    def test_mac_staged_pkg_path_must_match_original_builder_digest_line(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proof = {'target':'macos-arm64','source':{'commit':'f'*40}, **native_fixture(root,'macos-arm64',{}),
                     'installer':installer_fixture(root,'macos-arm64','a'*64)}
            proof['installer']['commands'][2]['arguments'][-1] = '/completely/unrelated/build-output'
            with self.assertRaises(ValueError):
                validate_installer(proof,root,'a'*64)

    def test_missing_installer_cannot_finalize(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'installer'):
                validate_installer({'target': 'linux-x64'}, Path(temp), 'a' * 64)


if __name__ == '__main__':
    unittest.main()
