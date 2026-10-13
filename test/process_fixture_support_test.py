import os
import nturl2path
from pathlib import Path
import subprocess
import tempfile
import unittest

from process_fixture_support import dart_executable, compile_runtime_tripwire, file_uri_path


# Optional only for local development. Required CI controls cannot silently skip.
if os.environ.get('CI'):
    missing = [name for name in ['ARCHWAY_TEST_DART_SDK'] if not os.environ.get(name)]
    if missing:
        raise RuntimeError('Missing required native-fixture CI prerequisites: ' + ', '.join(missing))


class RuntimeTripwireTest(unittest.TestCase):
    def test_windows_file_uri_decodes_drive_unicode_and_percent_once(self):
        self.assertEqual(
            file_uri_path('file:///D:/cache/caf%C3%A9%20%2520/collection-1.19.1',
                          decoder=nturl2path.url2pathname),
            'D:\\cache\\café %20\\collection-1.19.1')

    def test_windows_file_uri_supports_unc_and_localhost(self):
        for uri, expected in [
            ('file://server/share/caf%C3%A9%20%2525', r'\\server\share\café %25'),
            ('file:////server/share/path', r'\\server\share\path'),
            ('file://localhost/C:/cache/pkg', r'C:\cache\pkg'),
        ]:
            self.assertEqual(file_uri_path(uri, decoder=nturl2path.url2pathname), expected)

    def test_native_file_uri_round_trip(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'café %20'
            path.mkdir()
            self.assertEqual(Path(file_uri_path(path.as_uri())), path)

    def test_non_file_or_decorated_uri_is_rejected(self):
        for uri in ['https://example.org/pkg', 'file:relative', 'file:///pkg?query',
                    'file:///pkg#fragment', 'file://user@server/share/pkg']:
            with self.assertRaises(ValueError):
                file_uri_path(uri)

    def test_executable_names_follow_target(self):
        self.assertEqual(dart_executable(Path('sdk'), windows=True), Path('sdk/bin/dart.exe'))
        self.assertEqual(dart_executable(Path('sdk'), windows=False), Path('sdk/bin/dart'))

    @unittest.skipUnless(os.environ.get('ARCHWAY_TEST_DART_SDK'), 'local-only skip: set ARCHWAY_TEST_DART_SDK')
    def test_native_tripwire_records_execution_and_forwards_real_version(self):
        sdk = Path(os.environ['ARCHWAY_TEST_DART_SDK'])
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            binary = base / ('dart.exe' if os.name == 'nt' else 'dart')
            marker = base / 'marker café'
            compile_runtime_tripwire(sdk, binary, marker, delegate=dart_executable(sdk))
            result = subprocess.run([str(binary), '--version'], capture_output=True, check=True)
            self.assertIn(b'Dart SDK version: 3.13.3 ', result.stdout + result.stderr)
            self.assertEqual(marker.read_text().splitlines(), ['query'])
            compile_runtime_tripwire(sdk, binary, marker)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 99)
            self.assertEqual(marker.read_text().splitlines(), ['query', 'query'])


if __name__ == '__main__':
    unittest.main()
