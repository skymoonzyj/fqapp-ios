import copy
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / 'renew.py'
if MODULE.exists():
    spec = importlib.util.spec_from_file_location('renew', MODULE)
    renew = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renew)
else:
    renew = None

NOW = datetime(2026, 10, 22, 12, tzinfo=timezone.utc)
TEAM = 'TEAMID1234'
BUNDLE = 'com.fqapp.fqapp'
UDID = 'FAKE0000-DEVICE000000000001'
CERT = b'test certificate DER bytes'
SHA1 = hashlib.sha1(CERT).hexdigest().upper()


def config(root):
    return dict(schema_version=1, bundle_id=BUNDLE, team_id=TEAM, device_udid=UDID,
                version='1.0.0', build='1', source_app=str(root / 'source/Runner.app'),
                source_manifest=str(root / 'manifest.json'),
                provisioning_project=str(root / 'ProfilePreparation.xcodeproj'),
                provisioning_scheme='ProfilePreparation', allowed_certificate_sha1=[SHA1],
                renewal_window_hours=48, profile_cache_dirs=[str(root / 'cache')])


def entitlements():
    return {'application-identifier': TEAM + '.' + BUNDLE,
            'com.apple.developer.team-identifier': TEAM, 'get-task-allow': True,
            'keychain-access-groups': [TEAM + '.' + BUNDLE]}


def profile():
    return {'UUID': 'new-profile', 'TeamIdentifier': [TEAM],
            'ApplicationIdentifierPrefix': [TEAM], 'ProvisionedDevices': [UDID],
            'CreationDate': datetime(2026, 10, 22, 11),
            'ExpirationDate': datetime(2026, 10, 29, 11),
            'DeveloperCertificates': [CERT], 'Entitlements': entitlements()}


def initial_state():
    return dict(schema_version=1, status='healthy', message='正常', paused=False,
                installed_expires_at='2026-10-23T12:00:00Z', last_check_at=None,
                last_success_at=None, next_check_at=None, error_code=None,
                notification_id=None, last_run_dir=None)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(renew, 'renewal engine must exist')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cfg = config(self.root)

    def test_due_threshold_inclusive_and_force(self):
        self.assertFalse(renew.is_due('2026-10-24T12:00:01Z', NOW, 48))
        self.assertTrue(renew.is_due('2026-10-24T12:00:00Z', NOW, 48))
        self.assertTrue(renew.is_due('2026-10-20T12:00:00Z', NOW, 48))

    def test_profile_must_extend_installed_expiry(self):
        self.assertEqual(renew.validate_profile(profile(), self.cfg,
                         '2026-10-23T12:00:00Z', NOW), '2026-10-29T11:00:00Z')
        with self.assertRaises(renew.RenewalError):
            renew.validate_profile(profile(), self.cfg, '2026-10-29T11:00:00Z', NOW)

    def test_profile_with_short_remaining_lifetime_is_deferred(self):
        p = profile()
        p['ExpirationDate'] = datetime(2026, 10, 23, 12, 1)
        with self.assertRaises(renew.Deferred):
            renew.validate_profile(p, self.cfg, '2026-10-23T12:00:00Z', NOW)

    def test_profile_can_grant_team_keychain_wildcard_while_app_must_narrow_it(self):
        p = profile()
        p['Entitlements']['keychain-access-groups'] = [TEAM + '.*']
        renew.validate_profile(p, self.cfg, '2026-10-23T12:00:00Z', NOW)
        with self.assertRaises(renew.RenewalError):
            renew.validate_entitlements(p['Entitlements'], self.cfg)

    def test_profile_rejects_wrong_team_device_app_or_certificate(self):
        mutations = [lambda p: p.update(TeamIdentifier=['OTHERTEAM']),
                     lambda p: p.update(ProvisionedDevices=['other-device']),
                     lambda p: p['Entitlements'].update({'application-identifier': TEAM + '.*'}),
                     lambda p: p.update(DeveloperCertificates=[b'other cert']),
                     lambda p: p.update(ProvisionsAllDevices=True)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                p = profile()
                mutate(p)
                with self.assertRaises(renew.RenewalError):
                    renew.validate_profile(p, self.cfg, '2026-10-23T12:00:00Z', NOW)

    def test_entitlements_reject_extra_or_wildcard_grants(self):
        renew.validate_entitlements(entitlements(), self.cfg)
        for key, value in [('aps-environment', 'development'),
                           ('keychain-access-groups', [TEAM + '.*']),
                           ('get-task-allow', 1)]:
            invalid = entitlements()
            invalid[key] = value
            with self.assertRaises(renew.RenewalError):
                renew.validate_entitlements(invalid, self.cfg)

    def test_profile_cache_restores_only_matching_profiles_after_failure(self):
        cache = self.root / 'cache'
        cache.mkdir()
        matching = cache / 'matching.mobileprovision'
        matching.write_bytes(b'matching')
        unrelated = cache / 'other.mobileprovision'
        unrelated.write_bytes(b'unrelated')
        bad = cache / 'corrupt.mobileprovision'
        bad.write_bytes(b'bad')
        def decode(path):
            if path == matching:
                return profile()
            if path == unrelated:
                p = profile()
                p['Entitlements']['application-identifier'] = TEAM + '.other.app'
                return p
            raise renew.RenewalError('profile_invalid')
        with self.assertRaisesRegex(RuntimeError, 'build failed'):
            with renew.isolate_matching_profiles(self.cfg, self.root / 'run', decode):
                self.assertFalse(matching.exists())
                self.assertEqual(unrelated.read_bytes(), b'unrelated')
                self.assertEqual(bad.read_bytes(), b'bad')
                raise RuntimeError('build failed')
        self.assertEqual(matching.read_bytes(), b'matching')
        self.assertEqual(unrelated.read_bytes(), b'unrelated')
        saved = list((self.root / 'run/profile-backup').rglob('*.mobileprovision'))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_bytes(), b'matching')
        self.assertNotEqual(saved[0].stat().st_ino, matching.stat().st_ino)

    def test_incomplete_cache_journal_recovers_absent_original_only(self):
        cache = self.root / 'cache'
        cache.mkdir()
        original = cache / 'old.mobileprovision'
        run = self.root / 'runs/run1'
        saved = run / 'profile-backup/0/old.mobileprovision'
        saved.parent.mkdir(parents=True)
        saved.write_bytes(b'old profile')
        journal = run / 'profile-backup/restore.json'
        journal.write_text(json.dumps({'complete': False, 'files': [
            {'original': str(original), 'backup': str(saved)}]}))
        renew.recover_profile_backups(self.cfg, self.root / 'runs', lambda p: profile())
        self.assertEqual(original.read_bytes(), b'old profile')
        self.assertEqual(saved.read_bytes(), b'old profile')
        self.assertTrue(json.loads(journal.read_text())['complete'])
        original.unlink()
        renew.recover_profile_backups(self.cfg, self.root / 'runs', lambda p: profile())
        self.assertFalse(original.exists(), 'completed journals must not resurrect deliberately removed profiles')

    def test_cache_restoration_does_not_overwrite_new_profile(self):
        cache = self.root / 'cache'
        cache.mkdir()
        matching = cache / 'same.mobileprovision'
        matching.write_bytes(b'old')
        with renew.isolate_matching_profiles(self.cfg, self.root / 'run', lambda p: profile()):
            matching.write_bytes(b'new')
        self.assertEqual(matching.read_bytes(), b'new')
        self.assertIn(b'old', [p.read_bytes() for p in (self.root / 'run/profile-backup').rglob('*.mobileprovision')])

    def test_source_integrity_rejects_corruption_extra_files_and_symlinks(self):
        app = Path(self.cfg['source_app'])
        app.mkdir(parents=True)
        info = dict(CFBundleIdentifier=BUNDLE, CFBundleShortVersionString='1.0.0', CFBundleVersion='1')
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Runner').write_bytes(b'app')
        manifest = {'files': {p.name: {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                                      'mode': p.stat().st_mode & 0o7777} for p in app.iterdir()},
                    'bundle_id': BUNDLE, 'version': '1.0.0', 'build': '1'}
        renew.verify_source(app, manifest, self.cfg)
        (app / 'Runner').write_bytes(b'corrupt')
        with self.assertRaises(renew.RenewalError):
            renew.verify_source(app, manifest, self.cfg)
        (app / 'Runner').write_bytes(b'app')
        (app / 'extra').write_bytes(b'extra')
        with self.assertRaises(renew.RenewalError):
            renew.verify_source(app, manifest, self.cfg)
        (app / 'extra').unlink()
        (app / 'Runner').unlink()
        (app / 'Runner').symlink_to(app / 'Info.plist')
        with self.assertRaises(renew.RenewalError):
            renew.verify_source(app, manifest, self.cfg)

    def test_install_and_version_receipts_reject_partial_success(self):
        good = {'info': {'outcome': 'success'}, 'result': {'installedApplications': [{'bundleID': BUNDLE}]}}
        renew.validate_install_receipt(good, self.cfg)
        for invalid in [{}, {'info': {'outcome': 'failed'}, 'result': good['result']},
                        {'info': good['info'], 'result': {'installedApplications': [{'bundleID': 'other'}]}}]:
            with self.assertRaises(renew.RenewalError):
                renew.validate_install_receipt(invalid, self.cfg)
        apps = {'info': {'outcome': 'success'}, 'result': {'apps': [{'bundleIdentifier': BUNDLE,
                'version': '1.0.0', 'bundleVersion': '1'}]}}
        renew.validate_installed_apps(apps, self.cfg)
        apps['result']['apps'][0]['bundleVersion'] = '2'
        with self.assertRaises(renew.RenewalError):
            renew.validate_installed_apps(apps, self.cfg)

    def prepare_home(self):
        home = self.root / 'home'
        home.mkdir(mode=0o700)
        (home / 'config.json').write_text(json.dumps(self.cfg))
        (home / 'state.json').write_text(json.dumps(initial_state()))
        return home

    def test_failed_install_does_not_advance_expiry_or_success(self):
        home = self.prepare_home()
        class Backend:
            def renew(self, cfg, state, run):
                raise renew.RenewalError('install_failed')
        outcome, code = renew.execute(home, 'renew', now=NOW, backend=Backend())
        stored = json.loads((home / 'state.json').read_text())
        self.assertEqual(code, 1)
        self.assertEqual(outcome['status'], 'error')
        self.assertEqual(stored['installed_expires_at'], '2026-10-23T12:00:00Z')
        self.assertIsNone(stored['last_success_at'])

    def test_offline_defers_hourly_and_notification_is_stable(self):
        home = self.prepare_home()
        class Backend:
            def renew(self, cfg, state, run):
                raise renew.Deferred('device_unavailable')
        a, code = renew.execute(home, 'check', now=NOW, backend=Backend())
        b, _ = renew.execute(home, 'check', now=NOW, backend=Backend())
        self.assertEqual(code, 0)
        self.assertEqual(a['status'], 'deferred')
        self.assertEqual(a['next_check_at'], '2026-10-22T13:00:00Z')
        self.assertEqual(a['notification_id'], b['notification_id'])
        self.assertEqual(a['installed_expires_at'], '2026-10-23T12:00:00Z')

    def test_success_advances_expiry_once_and_keeps_config_immutable(self):
        home = self.prepare_home()
        before = (home / 'config.json').read_bytes()
        class Backend:
            def renew(self, cfg, state, run):
                return '2026-10-29T11:00:00Z'
        outcome, code = renew.execute(home, 'renew', now=NOW, backend=Backend())
        self.assertEqual(code, 0)
        self.assertEqual(outcome['installed_expires_at'], '2026-10-29T11:00:00Z')
        self.assertEqual(outcome['last_success_at'], '2026-10-22T12:00:00Z')
        self.assertIsNotNone(outcome['notification_id'])
        self.assertEqual(before, (home / 'config.json').read_bytes())
        self.assertEqual((home / 'state.json').stat().st_mode & 0o777, 0o600)

    def test_lock_prevents_second_renewal_and_status_never_mutates(self):
        home = self.prepare_home()
        before = (home / 'state.json').read_bytes()
        with renew.engine_lock(home):
            outcome, code = renew.execute(home, 'renew', now=NOW)
        self.assertEqual(code, 0)
        self.assertEqual(outcome['status'], 'busy')
        self.assertEqual(before, (home / 'state.json').read_bytes())
        files_before = set(home.iterdir())
        renew.execute(home, 'status', now=NOW)
        self.assertEqual(files_before, set(home.iterdir()))
        self.assertEqual(before, (home / 'state.json').read_bytes())

    def test_unfinished_native_command_fails_closed_while_group_exists(self):
        run = self.root / 'runs/old'
        run.mkdir(parents=True)
        journal = run / '001-xcodebuild.command.json'
        journal.write_text(json.dumps({'finished': False, 'process_group': os.getpgrp()}))
        with self.assertRaises(renew.UnsafeProcess):
            renew.check_unfinished_commands(self.root / 'runs')
        self.assertFalse(json.loads(journal.read_text())['finished'])
        journal.write_text(json.dumps({'finished': False, 'process_group': 2147483647}))
        renew.check_unfinished_commands(self.root / 'runs')
        self.assertTrue(json.loads(journal.read_text())['finished'])

    def test_command_runner_reaps_leader_exited_term_resistant_child(self):
        run = self.root / 'native'
        run.mkdir(mode=0o700)
        script = ('import os,signal,time; pid=os.fork(); '
                  'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                  'os._exit(0) if pid else time.sleep(30)')
        runner = renew.CommandRunner(run)
        runner.run([sys.executable, '-c', script], 5, 'provisioning_failed')
        journal = json.loads(next(run.glob('*.command.json')).read_text())
        self.assertTrue(journal['finished'])
        self.assertFalse(renew.process_group_exists(journal['process_group']))

    def test_optimized_python_keeps_identity_validation_enabled(self):
        script = ('import renew; '\
                  'cfg=' + repr(dict(self.cfg, bundle_id='another.app')) + '; '\
                  'renew.validate_config(cfg)')
        result = subprocess.run([sys.executable, '-O', '-c', script], cwd=str(MODULE.parent),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'config_invalid', result.stderr)

    def test_pause_blocks_scheduled_check_but_manual_renew_is_allowed(self):
        home = self.prepare_home()
        renew.execute(home, 'pause', now=NOW)
        class Backend:
            def renew(self, cfg, state, run):
                return '2026-10-29T11:00:00Z'
        outcome, _ = renew.execute(home, 'check', now=NOW, backend=Backend())
        self.assertEqual(outcome['status'], 'paused')
        outcome, _ = renew.execute(home, 'renew', now=NOW, backend=Backend())
        self.assertEqual(outcome['status'], 'renewed')
        self.assertTrue(outcome['paused'])

    def prepare_native_source(self):
        app = Path(self.cfg['source_app'])
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=BUNDLE,
            CFBundleShortVersionString='1.0.0', CFBundleVersion='1')))
        (app / 'Runner').write_bytes(b'actual Flutter application')
        for name in ['App', 'Flutter'] + ['Plugin%02d' % i for i in range(11)]:
            framework = app / 'Frameworks' / (name + '.framework')
            framework.mkdir(parents=True)
            (framework / name).write_bytes(b'framework executable')
        manifest = {'bundle_id': BUNDLE, 'version': '1.0.0', 'build': '1', 'files': {}}
        for path in app.rglob('*'):
            if path.is_file():
                manifest['files'][path.relative_to(app).as_posix()] = {
                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': path.stat().st_mode & 0o7777}
        Path(self.cfg['source_manifest']).write_text(json.dumps(manifest))
        return app

    def test_native_flow_installs_only_validated_actual_application(self):
        source = self.prepare_native_source()
        before = (source / 'Frameworks/App.framework/App').stat().st_mode
        home = self.prepare_home()
        runner = fake_runner(self.cfg)
        with mock.patch.object(renew, 'CommandRunner', runner), mock.patch.object(renew, 'utcnow', lambda: NOW):
            result, code = renew.execute(home, 'renew', now=NOW)
        self.assertEqual(code, 0, result)
        self.assertEqual(result['installed_expires_at'], '2026-10-29T11:00:00Z')
        self.assertTrue((Path(result['last_run_dir']) / 'installed-actual-app').is_file())
        self.assertEqual((source / 'Frameworks/App.framework/App').stat().st_mode, before)
        self.assertFalse((source / 'embedded.mobileprovision').exists())

    def test_native_failed_install_receipt_or_version_never_advances_expiry(self):
        self.prepare_native_source()
        home = self.prepare_home()
        for failure in ('install', 'after_version', 'before_version', 'offline'):
            with self.subTest(failure=failure):
                (home / 'state.json').write_text(json.dumps(initial_state()))
                with mock.patch.object(renew, 'CommandRunner', fake_runner(self.cfg, failure)), \
                        mock.patch.object(renew, 'utcnow', lambda: NOW):
                    result, code = renew.execute(home, 'renew', now=NOW)
                self.assertEqual(result['installed_expires_at'], '2026-10-23T12:00:00Z')
                self.assertIsNone(result['last_success_at'])
                if failure == 'offline':
                    self.assertEqual(result['status'], 'deferred')
                else:
                    self.assertEqual(code, 1)
                if failure in ('offline', 'before_version'):
                    self.assertFalse((Path(result['last_run_dir']) / 'DerivedData').exists())


def fake_runner(cfg, failure=None):
    """External tools alone are replaced; real engine filesystem/state flow runs."""
    class FakeRunner:
        def __init__(self, run, lock_fd=None):
            self.run_dir = Path(run)
            self.queries = 0
            self.framework_count = 0
            self.app_signed = False
            self.app_verified = False

        def run(self, argv, timeout, code):
            tool = Path(argv[0]).name
            assert timeout <= 600
            if tool == 'xcrun' and 'apps' in argv:
                self.queries += 1
                if failure == 'offline':
                    raise renew.RenewalError('device_unavailable')
                version = 'wrong' if (failure == 'before_version' or
                          failure == 'after_version' and self.queries == 3) else '1.0.0'
                data = {'info': {'outcome': 'success'}, 'result': {'apps': [
                    {'bundleIdentifier': BUNDLE, 'version': version, 'bundleVersion': '1'}]}}
                Path(argv[argv.index('--json-output') + 1]).write_text(json.dumps(data))
                return b''
            if tool == 'xcodebuild':
                assert self.queries == 1
                assert '-allowProvisioningUpdates' in argv
                stub = self.run_dir / 'DerivedData/Build/Products/Debug-iphoneos/ProfilePreparation.app'
                stub.mkdir(parents=True)
                (stub / 'embedded.mobileprovision').write_bytes(plistlib.dumps(profile()))
                return b''
            if tool == 'security':
                return Path(argv[-1]).read_bytes()
            if tool == 'codesign':
                target = Path(argv[-1])
                if '--entitlements' in argv and '-d' in argv:
                    return plistlib.dumps(entitlements())
                if any(a.startswith('--extract-certificates=') for a in argv):
                    prefix = next(a.split('=', 1)[1] for a in argv if a.startswith('--extract-certificates='))
                    Path(prefix + '0').write_bytes(CERT)
                    return b''
                if '--sign' in argv:
                    assert argv[argv.index('--sign') + 1] == SHA1
                    assert '--timestamp=none' in argv
                    if target.suffix == '.framework':
                        assert '--entitlements' not in argv
                        self.framework_count += 1
                    else:
                        assert target.name == 'Runner.app' and self.framework_count == 13
                        assert '--generate-entitlement-der' in argv
                        self.app_signed = True
                if '--verify' in argv and target.name == 'Runner.app':
                    assert self.app_signed and '--strict' in argv and '--deep' in argv
                    self.app_verified = True
                return b''
            if tool == 'xcrun' and 'install' in argv:
                assert self.app_verified and self.queries == 2
                target = Path(argv[argv.index('--device') + 2])
                assert target.name == 'Runner.app'
                assert (target / 'Runner').read_bytes() == b'actual Flutter application'
                assert (target / 'Frameworks/App.framework/App').stat().st_mode & 0o777 == 0o755
                (self.run_dir / 'installed-actual-app').write_text('verified actual app boundary')
                data = {'info': {'outcome': 'failed' if failure == 'install' else 'success'},
                        'result': {'installedApplications': [{'bundleID': BUNDLE}]}}
                Path(argv[argv.index('--json-output') + 1]).write_text(json.dumps(data))
                return b''
            raise AssertionError('Unexpected external tool invocation: ' + repr(argv))
    return FakeRunner


if __name__ == '__main__':
    unittest.main()
