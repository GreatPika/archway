"""Host refusal controls; actual pkg lifecycle requires macOS arm64 CI."""
from pathlib import Path
import platform
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from native_macos_installer_probe import run_macos


class MacNativeProbe(unittest.TestCase):
    @unittest.skipIf(platform.system() == 'Darwin', 'Wrong-host control only')
    def test_wrong_host_refuses_before_any_system_or_output_change(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'untouched'
            with self.assertRaisesRegex(ValueError, 'native macOS arm64'):
                run_macos(Path(temp) / 'missing', output, lambda *_: None)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
