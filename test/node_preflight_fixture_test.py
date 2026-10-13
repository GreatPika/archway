import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from node_preflight_fixture import compile_node_fixture


# Optional only for local development. Required CI controls cannot silently skip.
if os.environ.get('CI'):
    missing = [name for name in ['ARCHWAY_TEST_DART_SDK', 'ARCHWAY_TEST_NODE'] if not os.environ.get(name)]
    if missing:
        raise RuntimeError('Missing required native-fixture CI prerequisites: ' + ', '.join(missing))


@unittest.skipUnless(os.environ.get('ARCHWAY_TEST_DART_SDK') and os.environ.get('ARCHWAY_TEST_NODE'),
                     'local-only skip: set ARCHWAY_TEST_DART_SDK and ARCHWAY_TEST_NODE')
class NodePreflightFixtureTest(unittest.TestCase):
    def test_native_fixture_bounds_and_real_node_forwarding(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / ('node.exe' if os.name == 'nt' else 'node')
            configure = compile_node_fixture(Path(os.environ['ARCHWAY_TEST_DART_SDK']).resolve(),
                                             binary, Path(os.environ['ARCHWAY_TEST_NODE']).resolve())
            configure(stderr_bytes=65526)
            result = subprocess.run([str(binary), '--version'], capture_output=True, check=True)
            self.assertEqual(result.stdout, b'v24.21.0\n')
            self.assertEqual(len(result.stderr), 65526)
            configure(stderr_bytes=65527, exit_code=9)
            result = subprocess.run([str(binary), '--version'], capture_output=True)
            self.assertEqual(result.returncode, 9)
            self.assertEqual(len(result.stderr), 65527)
            result = subprocess.run([str(binary), '-p', 'JSON.stringify(process.versions.node)'],
                                    capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout), '24.21.0')
            echoed = subprocess.run([str(binary), '-e', 'process.stdin.pipe(process.stdout)'],
                                    input=b'\x00request\xff', capture_output=True, check=True)
            self.assertEqual(echoed.stdout, b'\x00request\xff')
            marker = root / 'query-marker'
            configure(marker=str(marker), version='')
            subprocess.run([str(binary), '--version'], check=True, capture_output=True)
            self.assertEqual(marker.read_text(), 'queried')


if __name__ == '__main__':
    unittest.main()
