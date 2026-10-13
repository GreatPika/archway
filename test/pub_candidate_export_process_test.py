"""Opt-in real pinned-pub export using synthetic bridges, never platform acceptance."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

import release_bundle_process_test

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('ARCHWAY_PUB_EXPORT_DART') and os.environ.get('ARCHWAY_PUB_EXPORT_CACHE'),
                     'explicit pinned Dart and prepared cache are required')
class CandidateExport(unittest.TestCase):
    def test_full_validation_exports_exact_source_once_with_expected_advisories(self):
        fixture = release_bundle_process_test.ReleaseBundles()
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        combined = fixture.base / 'combined'
        subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
                        'combine', '--expected-commit', fixture.commit, '--output', str(combined),
                        *[str(fixture.transports / target) for target in fixture.records]],
                       cwd=fixture.source, check=True, capture_output=True)
        evidence = Path(os.environ.get('ARCHWAY_PUB_EXPORT_EVIDENCE',
                                       fixture.base / 'candidate-evidence')).absolute()
        result = subprocess.run([sys.executable, str(ROOT / 'test/pub_package_process_smoke.py'),
                                 os.environ['ARCHWAY_PUB_EXPORT_DART'], str(fixture.source),
                                 str(combined), str(fixture.transports), fixture.commit, str(evidence),
                                 '--registry-ready', '--prepared-cache', os.environ['ARCHWAY_PUB_EXPORT_CACHE']],
                                capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((evidence / 'report.json').read_text())
        self.assertEqual(report['dry_run']['exit_code'], 65)
        self.assertEqual(report['archive_export']['exit_code'], 0)
        self.assertEqual(report['dry_run']['expected_advisories'], 7)
        self.assertEqual(report['archive_export']['expected_advisories'], 7)
        self.assertTrue((evidence / 'pub-package.tar.gz').is_file())
        self.assertEqual(json.loads((evidence / 'stage-identity.json').read_text())['upload_archive'],
                         report['upload_archive'])


if __name__ == '__main__':
    unittest.main()
