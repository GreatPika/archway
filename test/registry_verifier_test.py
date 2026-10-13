"""Candidate metadata verifier controls; synthetic payloads prove no runtime route."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

import package_metadata_test
import release_bundle_process_test

ROOT = Path(__file__).resolve().parents[1]


class RegistryVerifiers(unittest.TestCase):
    def setUp(self):
        self.fixture = package_metadata_test.RegistryMetadataTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.base = self.fixture.root
        self.installation = self.fixture.installation
        for path in (self.installation / 'bin').rglob('*'):
            if path.is_file():
                path.chmod(0o755)
        for name in ['vendor/typescript/LICENSE.txt', 'vendor/yaml/LICENSE',
                     'vendor/typescript/lib/lib.es2022.d.ts']:
            path = self.installation / 'assets/typescript' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic redistribution fixture')

    def stage(self, mode, candidate=True):
        output = self.base / mode
        command = [sys.executable, str(ROOT / 'tool/package_delivery.py'), mode,
                   str(output), str(self.installation)]
        if candidate:
            command.append('--registry-ready')
        subprocess.run(command, check=True, capture_output=True)
        return output

    def test_pub_stage_includes_verified_repository_metadata(self):
        stage = self.stage('pub')
        self.assertIn('repository: https://github.com/GreatPika/archway\n',
                      (stage / 'pubspec.yaml').read_text())
        self.assertIn('publish_to: none\n', (ROOT / 'pubspec.yaml').read_text())

    def test_release_wrapper_preserves_candidate_tarball_without_repacking(self):
        fixture = release_bundle_process_test.ReleaseBundles()
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        package = fixture.base / 'candidate'
        packed = fixture.base / 'candidate-packed'; packed.mkdir()
        subprocess.run([sys.executable, str(fixture.source / 'tool/package_delivery.py'),
                        'npm', str(package), str(fixture.base / 'installation'), '--registry-ready'],
                       check=True, capture_output=True)
        result = subprocess.run([shutil.which('npm'), 'pack', '--ignore-scripts', '--offline',
                                 '--json', '--pack-destination', str(packed),
                                 '--cache', str(self.base / 'npm-cache'), '--userconfig', os.devnull],
                                cwd=package, capture_output=True, check=True)
        (packed / 'npm-pack.json').write_bytes(result.stdout)
        subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
                        'verify-pack', '--package', str(package), '--packed-directory', str(packed),
                        '--registry-ready'], check=True, capture_output=True)
        tarball = packed / 'archway-architecture-cli-0.1.0.tgz'
        original = tarball.read_bytes()
        result = subprocess.run([sys.executable, str(ROOT / 'tool/release_bundles.py'),
                                 '--source', str(fixture.source), '--expected-commit', fixture.commit,
                                 '--transports', str(fixture.transports), '--packed', str(packed),
                                 '--guide', str(fixture.guide), '--output', str(fixture.output),
                                 '--registry-ready'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((fixture.output / tarball.name).read_bytes(), original)

    def test_pub_candidate_verifier_reconstructs_exact_source_metadata(self):
        fixture = release_bundle_process_test.ReleaseBundles()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        combined = fixture.base / 'combined'
        subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
                        'combine', '--expected-commit', fixture.commit, '--output', str(combined),
                        *[str(fixture.transports / target) for target in fixture.records]],
                       cwd=fixture.source, check=True, capture_output=True)
        stage = fixture.base / 'pub-candidate'
        subprocess.run([sys.executable, str(fixture.source / 'tool/package_delivery.py'),
                        'pub', str(stage), str(combined / 'installation'), '--registry-ready'],
                       check=True, capture_output=True)
        command = [sys.executable, str(ROOT / 'tool/ci/verify_pub_stage.py'), '--stage', str(stage),
                   '--source', str(fixture.source), '--combined', str(combined),
                   '--transports', str(fixture.transports), '--expected-commit', fixture.commit]
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        accepted = subprocess.run([*command, '--registry-ready'], capture_output=True, text=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIs(json.loads(accepted.stdout)['registry_ready'], True)
        spec = stage / 'pubspec.yaml'
        spec.write_text(spec.read_text().replace('version: 0.1.0', 'version: 0.2.0'))
        rejected = subprocess.run([*command, '--registry-ready'], capture_output=True, text=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('differs', rejected.stderr)

    def test_npm_candidate_refuses_missing_redistribution_license(self):
        (self.installation / 'assets/typescript/vendor/typescript/LICENSE.txt').unlink()
        package = self.stage('npm')
        packed = self.base / 'packed'; packed.mkdir()
        result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
                                 'verify-pack', '--package', str(package),
                                 '--packed-directory', str(packed), '--registry-ready'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('redistribution', result.stderr)
        self.assertFalse((packed / 'packed-evidence.json').exists())

    def test_npm_candidate_requires_explicit_verifier_intent(self):
        package = self.stage('npm')
        packed = self.base / 'packed'; packed.mkdir()
        npm = shutil.which('npm')
        self.assertIsNotNone(npm, 'npm is required for this focused packaging control')
        result = subprocess.run([npm, 'pack', '--ignore-scripts', '--offline', '--json',
                                 '--pack-destination', str(packed), '--cache', str(self.base / 'npm-cache'),
                                 '--userconfig', os.devnull], cwd=package,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        (packed / 'npm-pack.json').write_bytes(result.stdout)
        command = [sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
                   'verify-pack', '--package', str(package), '--packed-directory', str(packed)]
        rejected = subprocess.run(command, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        accepted = subprocess.run([*command, '--registry-ready'], capture_output=True, text=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        evidence = json.loads((packed / 'packed-evidence.json').read_text())
        self.assertIs(evidence['registry_ready'], True)
        self.assertGreater(evidence['compressed_bytes'], 0)


if __name__ == '__main__':
    unittest.main()
