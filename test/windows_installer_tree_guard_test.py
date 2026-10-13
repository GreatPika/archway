"""Source wiring guard only; real junction behavior requires the native lifecycle."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] /
          'tool/installers/windows/lifecycle.iss').read_text()


class WindowsTreeGuard(unittest.TestCase):
    def test_guard_precedes_upgrade_and_uninstall_mutation(self):
        prepare = SOURCE.split('function PrepareToInstall', 1)[1].split(
            'procedure ', 1)[0]
        self.assertIn('if WasOwned then NoReparseTree(InstallRoot);', prepare)
        uninstall = SOURCE.split('procedure CurUninstallStepChanged', 1)[1]
        self.assertLess(uninstall.index('NoReparseTree(InstallRoot);'),
                        uninstall.index('RemoveOwnedPath;'))

    def test_native_enumeration_has_explicit_error_and_close_boundary(self):
        self.assertIn('Require(SizeOf(Data) = 592', SOURCE)
        self.assertIn('ErrorCode = 18', SOURCE)
        self.assertIn('finally\n    Require(CloseFindHandle(Handle)', SOURCE)
        self.assertIn('ErrorCode := DLLGetLastError;', SOURCE)
        self.assertNotIn('(Attributes = $FFFFFFFF) or', SOURCE)


if __name__ == '__main__':
    unittest.main()
