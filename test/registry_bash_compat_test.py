"""Inert argument checks, runnable with ARCHWAY_TEST_BASH=/path/to/bash3.2."""
import os
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('ARCHWAY_TEST_BASH', 'bash')


class RegistryBashCompatibility(unittest.TestCase):
    def test_workflow_optional_arrays_preserve_argv_under_nounset(self):
        raw = (ROOT / '.github/workflows/package-delivery-probe.yml').read_text()
        steps = yaml.load(raw, Loader=yaml.BaseLoader)['jobs']['audit']['steps']
        producer = next(step['run'] for step in steps if step.get('id') == 'pub-transport')
        setup = next(step['run'] for step in steps if step.get('name') ==
                     'Prepare explicit Python and official pinned pub producer Dart')
        blocks = {
            'registry_args': 'source tool/ci/registry_candidate_arguments.sh\n',
            'pub_args': producer.split('python -u test/pub_package_process_smoke.py', 1)[0],
            'setup_args': 'source tool/ci/registry_candidate_arguments.sh\n' +
                setup.split('source tool/ci/registry_candidate_arguments.sh\n', 1)[1].split(
                    'python -u tool/ci/setup_pub_dart.py', 1)[0],
        }
        for name, preamble in blocks.items():
            expansion = '${' + name + '[@]+"${' + name + '[@]}"}'
            self.assertIn(expansion, raw)
            # No unguarded occurrence may survive in another workflow owner.
            self.assertNotIn('"${' + name + '[@]}"', raw.replace(expansion, ''))
            command = preamble + "capture() { printf '%s\\0' before \"$@\" after; }; capture " + expansion
            for intent in ['false', 'true', 'invalid', '']:
                result = subprocess.run([BASH, '-euc', command], cwd=ROOT, capture_output=True,
                    env={**os.environ, 'ARCHWAY_REGISTRY_READY': intent,
                         'PUB_PREPARED_CACHE': '/inert/cache café with spaces'})
                with self.subTest(array=name, intent=intent):
                    if intent not in ('false', 'true'):
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, b'')
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = []
                    if intent == 'true':
                        expected = (['--prepare-cache'] if name == 'setup_args' else ['--registry-ready'])
                        if name == 'pub_args':
                            expected += ['--prepared-cache', '/inert/cache café with spaces']
                    self.assertEqual(result.stdout.decode().split('\0'), ['before', *expected, 'after', ''])


if __name__ == '__main__':
    unittest.main()
