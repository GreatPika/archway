"""Mocked existing identity-control CLI; never runs package verification."""
from types import SimpleNamespace
from pathlib import Path
import json
import os
import tempfile
import unittest
from unittest.mock import patch
import pub_stage_identity_test as identity_control


class RegistryIdentityCli(unittest.TestCase):
    def test_identity_control_forwards_explicit_intent_without_running_verifier(self):
        for intent in (False, True):
            arguments = ['stage', 'source', 'combined', 'transports', 'a' * 40]
            if intent:
                arguments.append('--registry-ready')
            with patch.object(identity_control.subprocess, 'run', side_effect=ValueError('stop')) as run:
                with self.assertRaisesRegex(ValueError, 'stop'):
                    identity_control.main(arguments)
                command = run.call_args.args[0]
                self.assertEqual('--registry-ready' in command, intent)
                self.assertEqual(command[command.index('--expected-commit') + 1], 'a' * 40)

    @unittest.skipIf(os.name == 'nt', 'Temporary symlink control requires POSIX')
    def test_both_intents_mutate_private_to_the_opposite_and_restore_commit(self):
        for intent in (False, True):
            with tempfile.TemporaryDirectory() as temporary:
                stage = Path(temporary)
                manifest = stage / 'manifest.json'
                original = {'partial': False, 'private': not intent,
                            'targets': ['linux-x64', 'macos-arm64', 'windows-x64']}
                manifest.write_text(json.dumps(original))
                for name in ['native/windows-x64/archway_io.dll', 'bin/archway.dart',
                             'assets/typescript/licenses/pnpm-MIT.txt',
                             'schemas/public-result.schema.json', 'pubspec.yaml']:
                    path = stage / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('inert fixture')
                calls = []
                def mocked(command, **kwargs):
                    calls.append((command.copy(), json.loads(manifest.read_text())))
                    # This is a forwarding/mutation observation, not a verifier.
                    success = len(calls) in (1, 14)
                    return SimpleNamespace(returncode=0 if success else 1, stdout='', stderr='')
                arguments = [str(stage), str(stage), 'combined', 'transports', 'a' * 40]
                if intent:
                    arguments.append('--registry-ready')
                with patch.object(identity_control.subprocess, 'run', side_effect=mocked), patch('builtins.print'):
                    identity_control.main(arguments)
                self.assertEqual(len(calls), 14)
                self.assertEqual(calls[11][1]['private'], intent)
                self.assertEqual(calls[12][0][calls[12][0].index('--expected-commit') + 1], '0' * 40)
                self.assertEqual(calls[13][0][calls[13][0].index('--expected-commit') + 1], 'a' * 40)
                self.assertEqual(json.loads(manifest.read_text()), original)


if __name__ == '__main__':
    unittest.main()
