"""Unit checks for distribution metadata; synthetic assets are not runtime proof."""
import hashlib
import importlib.util
import json
import re
from urllib.parse import urlsplit
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'package_delivery', Path(__file__).resolve().parents[1] / 'tool/package_delivery.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackageMetadataTest(unittest.TestCase):
    def assert_packaged_readme_link(self, link):
        parsed = urlsplit(link)
        self.assertEqual(parsed.scheme, 'https', link)
        self.assertEqual(parsed.netloc, 'github.com', link)
        if link == 'https://github.com/GreatPika/archway/releases':
            return
        prefix = '/GreatPika/archway/blob/main/'
        self.assertTrue(parsed.path.startswith(prefix), link)
        target = packaging.REPOSITORY / parsed.path.removeprefix(prefix)
        self.assertTrue(target.is_file(), link)
        if parsed.fragment:
            headings = re.findall(r'^#+ (.+)$', target.read_text(), re.MULTILINE)
            anchors = {re.sub(r'[^\w -]', '', heading.lower()).replace(' ', '-')
                       for heading in headings}
            self.assertIn(parsed.fragment, anchors, link)

    def test_packaged_readme_releases_link_is_exact(self):
        self.assert_packaged_readme_link('https://github.com/GreatPika/archway/releases')
        for link in (
            'https://github.com/OtherOwner/archway/releases',
            'https://github.com/GreatPika/other/releases',
            'https://github.com/GreatPika/archway/releases-extra',
            'https://github.com/GreatPika/archway/releases/tag/other',
            'https://github.com/GreatPika/archway/releases?other=true',
            'https://github.com/GreatPika/archway/releases#other',
            'http://github.com/GreatPika/archway/releases',
            'https://github.com.example/GreatPika/archway/releases',
        ):
            with self.subTest(link=link), self.assertRaises(AssertionError):
                self.assert_packaged_readme_link(link)

    def test_all_target_npm_describes_product_without_enabling_registry_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installation = root / 'installation'
            for target, (executable, bridge) in packaging.TARGETS.items():
                for relative in [f'bin/{target}/{executable}', f'native/{target}/{bridge}']:
                    file = installation / relative
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_bytes(b'unit fixture; not an executable')
            for notice in ['pnpm-MIT.txt', 'yaml-ISC.txt']:
                file = installation / 'assets/typescript/licenses' / notice
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('unit fixture notice')
            output = root / 'package'
            packaging.stage('npm', output, installation)
            package = json.loads((output / 'package.json').read_text())
            self.assertEqual(package['description'],
                             'Architecture policy CLI for TypeScript and Dart projects.')
            self.assertEqual(package['license'], 'MIT')
            self.assertEqual((output / 'LICENSE').read_bytes(),
                             (packaging.REPOSITORY / 'LICENSE').read_bytes())
            self.assertTrue(package['private'])
            self.assertEqual(package['version'], '0.1.0')
            self.assertNotIn('scripts', package)
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertFalse(manifest['partial'])
            self.assertEqual(manifest['targets'], list(packaging.TARGETS))
            self.assertIn('LICENSE', manifest['sha256'])
            pub_output = root / 'pub-package'
            packaging.stage('pub', pub_output, installation)
            self.assertEqual((pub_output / 'LICENSE').read_bytes(),
                             (packaging.REPOSITORY / 'LICENSE').read_bytes())
            self.assertIn('publish_to: none', (pub_output / 'pubspec.yaml').read_text())
            for package_root in [output, pub_output]:
                readme = (package_root / 'README.md').read_text()
                self.assertEqual(readme, (packaging.REPOSITORY / 'tool/npm/README.md').read_text())
                links = re.findall(r'\[[^\]]+\]\(([^)]+)\)', readme)
                self.assertTrue(links, 'The installed README must link to its documentation.')
                for link in links:
                    self.assert_packaged_readme_link(link)
                schema_names = {'policy.schema.json', 'public-result.schema.json',
                                'export-diagnostics.schema.json'}
                self.assertEqual({path.relative_to(package_root / 'schemas').as_posix()
                                  for path in (package_root / 'schemas').rglob('*')}, schema_names)
                hashes = json.loads((package_root / 'manifest.json').read_text())['sha256']
                self.assertEqual({name for name in hashes if name.startswith('schemas/')},
                                 {'schemas/' + name for name in schema_names})
                for name in schema_names:
                    self.assertEqual((package_root / 'schemas' / name).read_bytes(),
                                     (packaging.REPOSITORY / 'contracts/json' / name).read_bytes())
                    pending = [json.loads((package_root / 'schemas' / name).read_text())]
                    while pending:
                        value = pending.pop()
                        if isinstance(value, dict):
                            if '$ref' in value:
                                self.assertTrue(value['$ref'].startswith('#'), value['$ref'])
                            pending.extend(value.values())
                        elif isinstance(value, list):
                            pending.extend(value)
                for notice in ['pnpm-MIT.txt', 'yaml-ISC.txt']:
                    relative = Path('assets/typescript/licenses') / notice
                    self.assertEqual((package_root / relative).read_bytes(),
                                     (installation / relative).read_bytes())



class RegistryMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.installation = self.root / 'installation'
        for target, (executable, bridge) in packaging.TARGETS.items():
            for name in [f'bin/{target}/{executable}', f'native/{target}/{bridge}']:
                path = self.installation / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'synthetic metadata fixture, not runtime evidence')
        for notice in ['pnpm-MIT.txt', 'yaml-ISC.txt']:
            path = self.installation / 'assets/typescript/licenses' / notice
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic notice')

    def run_stage(self, mode, *options):
        self.output = self.root / mode
        return subprocess.run([sys.executable, str(packaging.REPOSITORY / 'tool/package_delivery.py'),
                               mode, str(self.output), str(self.installation), *options],
                              capture_output=True, text=True)

    def test_assembly_entrypoint_forwards_explicit_registry_option(self):
        output = self.root / 'assembled'
        result = subprocess.run(['sh', str(packaging.REPOSITORY / 'tool/assemble.sh'),
                                 'npm', str(output), str(self.installation), '--registry-ready'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIs(json.loads((output / 'package.json').read_text())['private'], False)

    def test_both_channels_include_hashed_release_notes_and_shared_guide(self):
        for mode in ['npm', 'pub']:
            with self.subTest(mode=mode):
                result = self.run_stage(mode, '--registry-ready')
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads((self.output / 'manifest.json').read_text())
                for name in ['README.md', 'CHANGELOG.md', 'LICENSE']:
                    path = self.output / name
                    self.assertTrue(path.is_file(), name)
                    self.assertEqual(manifest['sha256'][name],
                                     hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertEqual((self.output / 'README.md').read_bytes(),
                                 (packaging.REPOSITORY / 'tool/npm/README.md').read_bytes())
                self.assertEqual((self.output / 'CHANGELOG.md').read_bytes(),
                                 (packaging.REPOSITORY / 'CHANGELOG.md').read_bytes())

    def test_pub_candidate_changes_only_publication_destination_before_hashing(self):
        original = (packaging.REPOSITORY / 'pubspec.yaml').read_bytes()
        result = self.run_stage('pub', '--registry-ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = (self.output / 'pubspec.yaml').read_bytes()
        self.assertEqual(actual, original.replace(b'publish_to: none\n',
                                                  b'publish_to: https://pub.dev\n'))
        self.assertEqual((packaging.REPOSITORY / 'pubspec.yaml').read_bytes(), original)
        manifest = json.loads((self.output / 'manifest.json').read_text())
        self.assertIs(manifest['private'], False)
        self.assertEqual(manifest['sha256']['pubspec.yaml'], hashlib.sha256(actual).hexdigest())

    def test_partial_stages_refuse_registry_metadata_without_creating_output(self):
        for mode in ['npm-private-linux', 'pub-private-linux']:
            with self.subTest(mode=mode):
                result = self.run_stage(mode, '--registry-ready')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('all-target', result.stderr)
                self.assertFalse(self.output.exists())

    def test_npm_explicit_candidate_metadata_is_hashed_before_delivery(self):
        result = self.run_stage('npm', '--registry-ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads((self.output / 'package.json').read_text())
        manifest = json.loads((self.output / 'manifest.json').read_text())
        self.assertIs(metadata['private'], False)
        self.assertIs(manifest['private'], False)
        self.assertIs(manifest['partial'], False)
        self.assertEqual(metadata['name'], 'archway-architecture-cli')
        self.assertEqual(metadata['version'], '0.1.0')
        self.assertNotIn('scripts', metadata)
        self.assertEqual(manifest['sha256']['package.json'],
                         hashlib.sha256((self.output / 'package.json').read_bytes()).hexdigest())

if __name__ == '__main__':
    unittest.main()
