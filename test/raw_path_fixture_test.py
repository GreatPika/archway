import errno
import os
from pathlib import Path
import sys
import tempfile
import unittest

from raw_path_fixture import malformed_path


class RawPathFixtureTest(unittest.TestCase):
    def test_native_invalid_encoding_is_not_a_replacement_character(self):
        parent = Path('fixture')
        self.assertEqual(malformed_path(parent, 'bad', windows=True), 'fixture' + os.sep + 'bad\udcff')
        self.assertEqual(malformed_path(parent, 'bad', windows=False), b'fixture' + os.fsencode(os.sep) + b'bad\xff')
        self.assertNotIn('\ufffd', malformed_path(parent, 'bad', windows=True))

    def test_real_filesystem_rejects_malformed_names_on_apfs_or_roundtrips_them_separately(self):
        with tempfile.TemporaryDirectory() as temp:
            bad = malformed_path(Path(temp), 'bad')
            if sys.platform == 'darwin':
                # The supported macOS/APFS cell permits only valid UTF-8 names.
                # Assert rejection, not a skip or acceptance of arbitrary I/O errors.
                with self.assertRaises(OSError) as rejected:
                    with open(bad, 'wb') as output:
                        output.write(b'malformed')
                self.assertEqual(rejected.exception.errno, errno.EILSEQ)
                self.assertEqual(os.listdir(temp), [])
            else:
                with open(bad, 'wb') as output:
                    output.write(b'malformed')
            replacement = Path(temp) / 'bad\ufffd'
            replacement.write_bytes(b'valid')
            if sys.platform != 'darwin':
                with open(bad, 'rb') as source:
                    self.assertEqual(source.read(), b'malformed')
                os.unlink(bad)
            self.assertEqual(replacement.read_bytes(), b'valid')
            self.assertTrue(replacement.exists())


if __name__ == '__main__':
    unittest.main()
