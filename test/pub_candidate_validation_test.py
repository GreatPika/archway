"""Frozen pinned-SDK advisory classification; no registry writes."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import pub_stage_inventory as validation


class CandidateValidation(unittest.TestCase):
    def setUp(self):
        self.issues = (ROOT / 'test/fixtures/pub-tight-pin-advisories.txt').read_text()
        self.preamble = ('Resolving dependencies...\nDownloading packages...\nGot dependencies!\n'
            'Publishing archway 0.1.0 to https://pub.dev:\n└── errors.js (1 KB)\n\n'
            'Total compressed archive size: 62 KB.\nValidating package...\n')

    def test_unknown_missing_duplicate_or_changed_diagnostics_are_blocking(self):
        tail = 'The server may enforce additional checks.\n\nPackage has 7 warnings.\n'
        for stdout, stderr, status in [
            (self.issues.replace('analyzer: ^14.5.0', 'analyzer: ^14.6.0') + tail, '', 65),
            (self.issues.replace('"crypto"', '"path"') + tail, '', 65),
            (self.issues + '* Additional warning.\n' + tail, '', 65),
            (self.issues + tail, 'Unexpected stderr warning', 65),
            (self.issues + tail, '', 0),
            (self.issues + tail, '', 1),
            ('Error: validation failed\n' + self.issues + tail, '', 65),
            (self.issues.replace('following 7', 'following 6') + tail, '', 65),
            (self.issues + self.issues + tail, '', 65),
        ]:
            with self.subTest(stdout=stdout[:60], stderr=stderr, status=status):
                with self.assertRaises(ValueError):
                    validation.validate_pub_advisories(self.preamble + stdout, stderr, status)

    def test_diagnostics_before_expected_heading_are_rejected_for_both_commands(self):
        duplicate = self.issues.split('\n', 1)[1].split('\n\n', 1)[0] + '\n'
        for prefix in ['* Additional warning.\n', duplicate, '  Error: validation failed\n',
                       '1 package is discontinued.\n']:
            for export in [False, True]:
                with self.subTest(prefix=prefix, export=export):
                    tail = ('Wrote package archive at /tmp/pub-package.tar.gz\n' if export else
                            'The server may enforce additional checks.\n\nPackage has 7 warnings.\n')
                    with self.assertRaises(ValueError):
                        validation.validate_pub_advisories(prefix + self.preamble + self.issues + tail, '',
                                                           0 if export else 65, export=export)

    def test_observed_available_version_notice_is_informational_only(self):
        before = self.preamble.replace('Got dependencies!\n',
            '  matcher 0.12.18 (0.12.20 available)\n'
            '  package_config 2.2.0 (3.0.0 available)\n'
            '  unorm_dart 0.3.2 (0.3.3 available)\nGot dependencies!\n'
            '3 packages have newer versions incompatible with dependency constraints.\n'
            'Try `dart pub outdated` for more information.\n')
        stdout = before + self.issues + 'The server may enforce additional checks.\n\nPackage has 7 warnings.\n'
        self.assertEqual(validation.validate_pub_advisories(stdout, '', 65)['expected_advisories'], 7)
        with self.assertRaises(ValueError):
            validation.validate_pub_advisories(stdout.replace('3 packages', '4 packages'), '', 65)

    def test_package_filenames_are_not_diagnostics(self):
        stdout = self.preamble + self.issues
        stdout += 'The server may enforce additional checks.\n\nPackage has 7 warnings.\n'
        self.assertEqual(validation.validate_pub_advisories(stdout, '', 65)['expected_advisories'], 7)

    def test_retains_expected_dry_run_status_and_export_advisories(self):
        dry = self.preamble + self.issues + 'The server may enforce additional checks.\n\nPackage has 7 warnings.\n'
        proof = validation.validate_pub_advisories(dry, '', 65)
        self.assertEqual(proof, {'exit_code': 65, 'expected_advisories': 7})
        exported = self.preamble + self.issues + 'Wrote package archive at /tmp/pub-package.tar.gz\n'
        self.assertEqual(validation.validate_pub_advisories(exported, '', 0, export=True),
                         {'exit_code': 0, 'expected_advisories': 7})


if __name__ == '__main__':
    unittest.main()
