"""Preparation validation; these unit checks do not certify a native host."""
import importlib.util
from io import BytesIO
from urllib.error import HTTPError, URLError
import ssl
from pathlib import Path
import unittest
import tempfile
import json
import os
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prep', ROOT / 'tool/ci/prepare_native_acceptance.py')
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


class PreparationTests(unittest.TestCase):
    def test_download_retries_transient_gateway_errors(self):
        url = 'https://nodejs.org/dist/v24.19.0/SHASUMS256.txt'
        for status in (502, 503, 504):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                error = HTTPError(url, status, 'Transient upstream error', {}, BytesIO())
                with patch.object(prep, 'urlopen', side_effect=[error, BytesIO(b'complete')]) as opening, \
                        patch('time.sleep') as sleeping:
                    path = Path(tmp) / 'download'
                    prep.download(url, path)
                    self.assertEqual(path.read_bytes(), b'complete')
                    self.assertEqual(opening.call_args_list, [unittest.mock.call(url, timeout=180)] * 2)
                    sleeping.assert_called_once_with(1)
                    self.assertTrue(error.closed)

    def test_download_discards_partial_bytes_before_retry(self):
        url = 'https://nodejs.org/dist/v24.19.0/archive'
        error = HTTPError(url, 502, 'Transient upstream error', {}, BytesIO())

        class PartialResponse(BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise error
                return super().read(size)

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'archive'

            def wait(seconds):
                self.assertFalse(path.exists())

            with patch.object(prep, 'urlopen', side_effect=[PartialResponse(b'partial'), BytesIO(b'ok')]), \
                    patch('time.sleep', side_effect=wait):
                prep.download(url, path)
            self.assertEqual(path.read_bytes(), b'ok')

    def test_download_exhaustion_is_bounded_and_preserves_last_error(self):
        url = 'https://nodejs.org/dist/v24.19.0/archive'
        errors = [HTTPError(url, status, 'Unavailable', {}, BytesIO()) for status in (502, 503, 504)]
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(prep, 'urlopen', side_effect=errors) as opening, \
                patch('time.sleep') as sleeping:
            with self.assertRaises(HTTPError) as caught:
                prep.download(url, Path(tmp) / 'archive')
            self.assertIs(caught.exception, errors[-1])
            self.assertEqual(opening.call_count, 3)
            self.assertEqual(sleeping.call_args_list, [unittest.mock.call(1), unittest.mock.call(2)])
            self.assertTrue(all(error.closed for error in errors))

    def test_download_does_not_retry_other_http_or_transport_errors(self):
        url = 'https://nodejs.org/dist/v24.19.0/archive'
        errors = [HTTPError(url, status, 'Failure', {}, BytesIO())
                  for status in (400, 401, 403, 404, 408, 429, 500, 501)]
        errors += [URLError(ssl.SSLCertVerificationError('untrusted certificate')),
                   URLError('connection refused'), TimeoutError('timed out'),
                   PermissionError('access denied')]
        for error in errors:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(prep, 'urlopen', side_effect=error) as opening, \
                    patch('time.sleep') as sleeping:
                with self.assertRaises(type(error)) as caught:
                    prep.download(url, Path(tmp) / 'archive')
                self.assertIs(caught.exception, error)
                opening.assert_called_once_with(url, timeout=180)
                sleeping.assert_not_called()

    def test_download_still_rejects_checksum_mismatch_after_retry(self):
        url = 'https://nodejs.org/dist/v24.19.0/archive'
        error = HTTPError(url, 502, 'Unavailable', {}, BytesIO())
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(prep, 'urlopen', side_effect=[error, BytesIO(b'wrong')]) as opening, \
                patch('time.sleep') as sleeping:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                prep.download(url, Path(tmp) / 'archive', '0' * 64)
            self.assertEqual(opening.call_count, 2)
            sleeping.assert_called_once_with(1)

    def test_official_flutter_record_requires_all_pins(self):
        pin = prep.FLUTTER['linux-x64']
        record = dict(version='3.47.4', channel='stable', dart_sdk_version='3.13.3',
                      dart_sdk_arch='x64', archive=pin[0], sha256=pin[1])
        self.assertEqual(prep.flutter_record({'releases': [record]}, 'linux-x64'), record)
        for key in record:
            bad = dict(record, **{key: 'unexpected'})
            with self.subTest(key=key), self.assertRaises(ValueError):
                prep.flutter_record({'releases': [bad]}, 'linux-x64')

    def test_readiness_fails_missing_real_lock_or_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(FileNotFoundError):
                prep.readiness(root)
            for name in ['pub/hosted', 'pub/path', 'pub/workspace', 'git-fixture', 'flutter-fixture']:
                for file in ['pubspec.yaml', 'pubspec.lock']:
                    prep.write(root / name / file, 'prepared')
                prep.write(root / name / '.dart_tool/package_config.json', json.dumps({
                    'configVersion': 2, 'generatorVersion': '3.13.3'}))
            self.assertEqual(len(prep.readiness(root)), 5)
            (root / 'flutter-fixture/pubspec.lock').unlink()
            with self.assertRaises(FileNotFoundError):
                prep.readiness(root)

    def test_environment_isolated_from_personal_config_and_flutter_wrapper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dart = root / 'flutter/bin/cache/dart-sdk/bin/dart'
            with patch.dict(os.environ, {'GIT_CONFIG_COUNT': '99', 'PUB_CACHE': '/personal',
                                         'NODE_OPTIONS': '--require=personal', 'HOME': '/personal'}):
                env = prep.environment(root, dart, root / 'flutter')
            self.assertEqual(env['PUB_CACHE'], str(root / 'pub-cache'))
            self.assertEqual(env['HOME'], str(root / 'home'))
            self.assertEqual(env['GIT_CONFIG_COUNT'], '1')
            self.assertEqual(env['GIT_CONFIG_KEY_0'], 'core.hooksPath')
            self.assertNotIn('NODE_OPTIONS', env)
            self.assertEqual(env['PATH'].split(os.pathsep)[0], str(dart.parent))
            self.assertNotIn(str(root / 'flutter/bin'), env['PATH'].split(os.pathsep))

    def test_archive_checksum_is_mandatory(self):
        from io import BytesIO
        with tempfile.TemporaryDirectory() as tmp, patch.object(prep, 'urlopen', return_value=BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                prep.download('https://official.example/archive', Path(tmp) / 'archive', '0' * 64)


if __name__ == '__main__':
    unittest.main()
