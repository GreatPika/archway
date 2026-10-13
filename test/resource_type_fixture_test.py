import os
from pathlib import Path
import stat
import tempfile
import unittest

from resource_type_fixture import nonregular_resource, remove_nonregular_resource


class NonregularResourceTest(unittest.TestCase):
    def test_resource_exists_but_is_not_a_file_and_can_be_removed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'resource'
            nonregular_resource(path)
            self.assertTrue(path.exists())
            self.assertFalse(path.is_file())
            mode = path.stat().st_mode
            self.assertTrue(stat.S_ISDIR(mode) if os.name == 'nt' else stat.S_ISFIFO(mode))
            remove_nonregular_resource(path)
            self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()
