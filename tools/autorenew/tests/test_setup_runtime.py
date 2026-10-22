"""Offline bootstrap tests: every path lives in a temporary directory."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

from test_renew import config, renew

MODULE = Path(__file__).resolve().parents[1] / 'setup_runtime.py'
setup = None
if MODULE.exists():
    spec = importlib.util.spec_from_file_location('setup_runtime', MODULE)
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(setup, 'portable bootstrap must exist')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cfg = config(self.root)
        self.cfg['provisioning_project'] = str(self.root / 'project-input/ProfilePreparation.xcodeproj')
        self.cfg.pop('source_manifest')
        self.cfg['installed_expires_at'] = '2030-01-02T03:04:05Z'
        self.app = Path(self.cfg['source_app'])
        self.app.mkdir(parents=True)
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': self.cfg['bundle_id'],
            'CFBundleShortVersionString': self.cfg['version'],
            'CFBundleVersion': self.cfg['build'], 'CFBundleExecutable': 'Runner'}))
        (self.app / 'Runner').write_bytes(b'offline test executable')
        for name in ['App', 'Flutter'] + ['Plugin%02d' % i for i in range(11)]:
            framework = self.app / 'Frameworks' / (name + '.framework')
            framework.mkdir(parents=True)
            (framework / name).write_bytes(b'offline framework')
        self.project = Path(self.cfg['provisioning_project'])
        self.project.mkdir(parents=True)
        (self.project / 'project.pbxproj').write_text('// test project')
        scheme = self.project / 'xcshareddata/xcschemes/ProfilePreparation.xcscheme'
        scheme.parent.mkdir(parents=True)
        scheme.write_text('<Scheme/>')
        (self.project.parent / 'main.c').write_text('int main(void) { return 0; }\n')
        (self.project.parent / 'ProfilePreparation.entitlements').write_bytes(plistlib.dumps({
            'keychain-access-groups': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)']}))
        self.input = self.root / 'config.json'
        self.home = self.root / 'private-runtime'

    def bootstrap(self):
        self.input.write_text(json.dumps(self.cfg))
        return setup.bootstrap(self.input, self.home)

    def test_bootstrap_copies_verified_source_and_only_minimal_project_privately(self):
        (self.project / 'xcuserdata').mkdir()
        (self.project / 'xcuserdata/private').write_text('must not copy')
        (self.root / 'account.mobileprovision').write_text('must not copy')
        before = (self.app / 'Runner').read_bytes()
        self.bootstrap()
        saved = json.loads((self.home / 'config.json').read_text())
        renew.validate_config(saved)
        state = json.loads((self.home / 'state.json').read_text())
        renew.validate_state(state)
        self.assertEqual(state['installed_expires_at'], self.cfg['installed_expires_at'])
        self.assertIsNone(state['last_success_at'])
        self.assertEqual((self.app / 'Runner').read_bytes(), before)
        self.assertFalse(Path(saved['source_app']).is_symlink())
        self.assertEqual(Path(saved['source_app']).name, 'Runner.app')
        self.assertFalse(list((self.home / 'profile-preparation').rglob('xcuserdata')))
        self.assertFalse(list((self.home / 'profile-preparation').rglob('*.mobileprovision')))
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        for name in ('config.json', 'state.json', 'source-manifest.json'):
            self.assertEqual((self.home / name).stat().st_mode & 0o777, 0o600)
        manifest = renew.read_json(saved['source_manifest'], 'source_invalid')
        renew.verify_source(saved['source_app'], manifest, saved)

    def test_existing_runtime_is_never_overwritten(self):
        self.home.mkdir()
        marker = self.home / 'state.json'
        marker.write_text('keep this existing state')
        with self.assertRaises((ValueError, FileExistsError)):
            self.bootstrap()
        self.assertEqual(marker.read_text(), 'keep this existing state')
        self.assertEqual(list(self.home.iterdir()), [marker])

    def test_example_expiry_requires_real_installed_evidence(self):
        example = json.loads((MODULE.parent / 'config.example.json').read_text())
        self.cfg['installed_expires_at'] = example['installed_expires_at']
        with self.assertRaises(ValueError):
            self.bootstrap()
        self.assertFalse(self.home.exists())

    def test_invalid_local_inputs_fail_before_runtime_creation(self):
        cases = [('team_id', 'lowerteam1'), ('team_id', 'SHORT'),
                 ('source_app', 'relative/Runner.app'),
                 ('installed_expires_at', '2030-01-02'), ('version', '2.0.0')]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                old = self.cfg[key]
                self.cfg[key] = value
                with self.assertRaises((ValueError, setup.renew.RenewalError)):
                    self.bootstrap()
                self.assertFalse(self.home.exists())
                self.cfg[key] = old

    def test_signed_source_and_symlinks_are_rejected(self):
        profile = self.app / 'embedded.mobileprovision'
        profile.write_bytes(b'signed payload')
        with self.assertRaises((ValueError, setup.renew.RenewalError)):
            self.bootstrap()
        self.assertFalse(self.home.exists())
        profile.unlink()
        executable = self.app / 'Runner'
        executable.unlink()
        executable.symlink_to(self.app / 'Info.plist')
        with self.assertRaises((ValueError, setup.renew.RenewalError)):
            self.bootstrap()
        self.assertFalse(self.home.exists())


if __name__ == '__main__':
    unittest.main()
