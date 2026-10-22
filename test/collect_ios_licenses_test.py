import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/collect_ios_licenses.py'


class LicenseInventory(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'iOS license collector must exist')
        spec = importlib.util.spec_from_file_location('licenses', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        for name, text in {'LICENSE': 'App GPL license', 'pubspec.lock': 'packages:\n  dart_example:\n    version: "1.0.0"\n', 'rust/Cargo.lock': 'version = 3\n[[package]]\nname = "rust_example"\nversion = "1.0.0"\n', 'ios/Podfile.lock': 'PODS:\n  - PodExample (1.0.0)\nDEPENDENCIES:\n  - PodExample\n', '.dart_tool/package_config.json': json.dumps({'packages': [{'name': 'dart_example', 'rootUri': '../cache/dart_example'}]}), 'cache/dart_example/LICENSE': 'Dart license', 'cache/dart_example/pubspec.yaml': 'name: dart_example\nversion: 1.0.0\n', 'cache/rust_example/LICENSE-MIT': 'Rust license', 'flutter/LICENSE': 'Flutter license', 'flutter/bin/cache/LICENSE.engine': 'Engine license', 'native/third_party/tiny_aes/unlicense.txt': 'Tiny AES license'}.items():
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        (self.root / 'ios/Pods').mkdir(parents=True)
        (self.root / 'ios/Pods/Manifest.lock').write_bytes((self.root / 'ios/Podfile.lock').read_bytes())
        self.metadata = self.root / 'cargo-metadata.json'
        self.metadata.write_text(json.dumps({'packages': [{'name': 'rust_example', 'version': '1.0.0', 'manifest_path': str(self.root / 'cache/rust_example/Cargo.toml'), 'license': 'MIT'}]}))
        ack = self.root / 'ios/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist'
        ack.parent.mkdir(parents=True)
        ack.write_bytes(plistlib.dumps({'PreferenceSpecifiers': [{'Title': 'PodExample', 'FooterText': 'Pod license'}]}))
        self.output = self.root / 'licenses'

    def collect(self):
        return self.module.collect(self.root, self.output, self.metadata, self.root / 'flutter')

    def test_complete_inventory_includes_each_ecosystem_and_license_hashes(self):
        result = self.collect()
        self.assertEqual(result['status'], 'complete')
        names = {e['component'] for e in result['entries']}
        self.assertTrue({'dart:dart_example', 'rust:rust_example@1.0.0', 'pod:PodExample', 'native:tiny_aes', 'flutter', 'flutter-engine', 'fqapp'}.issubset(names))
        self.assertTrue(all(e['files'] for e in result['entries']))

    def test_missing_dependency_license_is_unknown_not_success(self):
        (self.root / 'cache/dart_example/LICENSE').unlink()
        result = self.collect()
        self.assertEqual(result['status'], 'incomplete')
        self.assertIn('dart:dart_example', result['unresolved'])

    def test_lock_dependency_missing_from_resolver_is_not_silently_omitted(self):
        (self.root / 'pubspec.lock').write_text('packages:\n  missing:\n    version: "1.0.0"\n')
        result = self.collect()
        self.assertIn('dart:missing', result['unresolved'])

    def test_missing_rust_metadata_and_pod_acknowledgments_are_unknown(self):
        self.metadata.unlink()
        (self.root / 'ios/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist').unlink()
        result = self.collect()
        self.assertEqual(result['status'], 'incomplete')
        self.assertIn('rust:rust_example@1.0.0', result['unresolved'])
        self.assertIn('pod:PodExample', result['unresolved'])

    def test_stale_dart_resolution_cannot_prove_current_version_license(self):
        (self.root / 'cache/dart_example/pubspec.yaml').write_text('name: dart_example\nversion: 0.9.0\n')
        result = self.collect()
        self.assertEqual(result['status'], 'incomplete')
        self.assertIn('dart:dart_example', result['unresolved'])

    def test_stale_installed_pods_cannot_prove_current_lock_license(self):
        (self.root / 'ios/Pods/Manifest.lock').write_text('stale installed pods')
        result = self.collect()
        self.assertEqual(result['status'], 'incomplete')
        self.assertIn('pod:PodExample', result['unresolved'])

    def test_existing_destination_is_never_overwritten(self):
        self.output.mkdir()
        (self.output / 'keep').write_text('previous evidence')
        with self.assertRaises(FileExistsError):
            self.collect()
        self.assertEqual((self.output / 'keep').read_text(), 'previous evidence')


if __name__ == '__main__':
    unittest.main()
