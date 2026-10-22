"""Small source/content and artifact control tests; never builds native code."""
import importlib.util
import json
import pathlib
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/ios_artifact_provenance.py'


def simulator_macho(payload, copies=1):
    """Tiny arm64 MH_EXECUTE with the section layout observed in Xcode 27 Runner."""
    size = 72 + 80 * copies
    offset = 32 + size
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, size, 0, 0)
    segment = struct.pack('<II16s4Q4I', 0x19, size, b'__TEXT', 0x100000000, offset + len(payload), 0, offset + len(payload), 7, 5, copies, 0)
    section = struct.pack('<16s16sQQ8I', b'__entitlements', b'__TEXT', 0x100000000 + offset, len(payload), offset, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section * copies + payload


def simulator_app(root, entitlements):
    app = root / 'app'
    app.mkdir(exist_ok=True)
    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Runner'}))
    (app / 'Runner').write_bytes(simulator_macho(plistlib.dumps(entitlements)))
    return app


class Provenance(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'build-time provenance helper must exist')
        spec = importlib.util.spec_from_file_location('provenance', SCRIPT)
        self.p = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.p)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        for name in ('rust/src/lib.rs', 'native/core.c', '.cargo/config.toml', 'lib/src/rust/frb_generated.dart', 'ios/Podfile', 'scripts/build_ios_core.sh', 'pubspec.yaml'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# fixture input' if name == '.cargo/config.toml' else 'fixture input')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], cwd=self.root, check=True)
        self.tools = patch.object(self.p, 'toolchain', return_value={'rustc': {'version': 'rustc fixture', 'executable_sha256': 'a' * 64}})
        self.tools.start()
        self.addCleanup(self.tools.stop)

    def capture(self, clean=False):
        return self.p.capture(self.root, 'native', 'release', 'device', clean)

    def test_clean_capture_records_config_and_binding_content(self):
        record = self.capture(True)
        self.assertFalse(record['source_dirty'])
        self.assertIn('.cargo/config.toml', record['source_sha256'])
        self.assertIn('lib/src/rust/frb_generated.dart', record['source_sha256'])
        self.assertEqual(len(record['source_commit']), 40)

    def test_release_rejects_dirty_but_development_records_real_hash(self):
        (self.root / 'rust/src/lib.rs').write_text('changed')
        with self.assertRaisesRegex(self.p.ProvenanceError, 'clean'):
            self.capture(True)
        record = self.capture(False)
        self.assertTrue(record['source_dirty'])
        self.assertEqual(record['source_sha256']['rust/src/lib.rs'], self.p.sha256(self.root / 'rust/src/lib.rs'))

    def test_post_build_mutation_rejected_even_if_mtime_unchanged(self):
        record = self.capture()
        path = self.root / 'native/core.c'
        stat = path.stat()
        path.write_text('different input')
        import os
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        with self.assertRaisesRegex(self.p.ProvenanceError, 'changed'):
            self.p.check_unchanged(self.root, record)

    def test_added_ignored_source_config_cannot_evade_inventory(self):
        record = self.capture()
        (self.root / '.cargo/config').write_text('# new config')
        with self.assertRaisesRegex(self.p.ProvenanceError, 'changed'):
            self.p.check_unchanged(self.root, record)

    def test_tool_binary_drift_rejected_despite_same_version(self):
        record = self.capture()
        with patch.object(self.p, 'toolchain', return_value={'rustc': {'version': 'rustc fixture', 'executable_sha256': 'b' * 64}}):
            with self.assertRaisesRegex(self.p.ProvenanceError, 'changed'):
                self.p.check_unchanged(self.root, record)

    def test_build_flags_are_hashed_without_exposing_secret_values(self):
        with patch.dict('os.environ', {'RUSTFLAGS': '--cfg SECRET_VALUE'}):
            record = self.capture()
        self.assertIn('RUSTFLAGS', record['environment_sha256'])
        self.assertNotIn('SECRET_VALUE', json.dumps(record))

    def test_device_outcome_cannot_be_created_from_simulator_inputs(self):
        before = self.p.capture(self.root, 'app', 'debug', 'simulator', True)
        with self.assertRaises(Exception) as raised:
            self.p.finalize(self.root, before, self.root / 'app', self.root / 'missing-manifest', self.root / 'out', 'unsigned-local-device', 'com.example.app', '1.0', '1')
        self.assertIsInstance(raised.exception, self.p.ProvenanceError)
        self.assertIn('kind', str(raised.exception))

    def test_source_symlink_cannot_escape_checkout(self):
        (self.root / 'native/escape.c').symlink_to('/etc/hosts')
        with self.assertRaisesRegex(self.p.ProvenanceError, 'escape'):
            self.capture()

    def test_simulator_entitlements_allow_only_the_two_app_scoped_keys(self):
        expected = {'application-identifier': 'com.example.app', 'keychain-access-groups': ['com.example.app']}
        simulator_app(self.root, expected)
        for extra in ({}, {'com.apple.developer.team-identifier': 'TEAM'}, {'com.apple.security.application-groups': ['group.other']}, {'get-task-allow': True}):
            with self.subTest(extra=extra):
                def codesign(args, root=None):
                    if '--entitlements' in args:
                        return plistlib.dumps(expected | extra).decode()
                    return 'Signature=adhoc\nTeamIdentifier=not set'
                with patch.object(self.p, 'command', codesign):
                    if extra:
                        with self.assertRaisesRegex(self.p.ProvenanceError, 'entitlement'):
                            self.p.verify_adhoc_simulator(self.root / 'app', 'com.example.app')
                    else:
                        self.assertEqual(self.p.verify_adhoc_simulator(self.root / 'app', 'com.example.app')['mode'], 'local-ad-hoc')

    def test_cc_flag_variants_and_modes_are_hashed_and_drift_is_rejected(self):
        keys = ['CFLAGS_aarch64_apple_ios', 'CFLAGS_aarch64_apple_ios_sim', 'CFLAGS_aarch64-apple-ios', 'CFLAGS_aarch64-apple-ios-sim', 'TARGET_CFLAGS', 'HOST_CFLAGS', 'CXXFLAGS_aarch64_apple_ios', 'TARGET_ARFLAGS', 'RANLIBFLAGS_aarch64-apple-ios', 'CC_SHELL_ESCAPED_FLAGS', 'CRATE_CC_NO_DEFAULTS']
        for key in keys:
            with self.subTest(key=key), patch.dict('os.environ', {key: 'SECRET_FIRST'}):
                before = self.capture()
                self.assertIn(key, before['environment_sha256'])
                self.assertNotIn('SECRET_FIRST', json.dumps(before))
                with patch.dict('os.environ', {key: 'SECRET_SECOND'}):
                    with self.assertRaisesRegex(self.p.ProvenanceError, 'changed'):
                        self.p.check_unchanged(self.root, before)

    def test_compiler_and_wrapper_overrides_rejected_even_at_same_path(self):
        wrapper = self.root / 'outside-wrapper'
        for contents in ('first secret body', 'changed secret body'):
            wrapper.write_text(contents)
            for key in ('RUSTC', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CARGO_BUILD_RUSTC', 'CC', 'CC_aarch64-apple-ios', 'CC_aarch64_apple_ios', 'TARGET_CC', 'HOST_CC', 'AR_aarch64_apple_ios_sim', 'CC_KNOWN_WRAPPER_CUSTOM', 'CARGO_TARGET_AARCH64_APPLE_IOS_LINKER'):
                with self.subTest(key=key, contents=contents), patch.dict('os.environ', {key: str(wrapper)}):
                    with self.assertRaisesRegex(self.p.ProvenanceError, 'unsupported.*override') as raised:
                        self.capture()
                    self.assertNotIn(str(wrapper), str(raised.exception))
                    self.assertNotIn(contents, str(raised.exception))
        with patch.dict('os.environ', {'CC_aarch64-apple-ios': ''}):
            with self.assertRaisesRegex(self.p.ProvenanceError, 'unsupported.*override'):
                self.capture()

    def test_cargo_compiler_configuration_and_environment_injection_rejected(self):
        configurations = ['[build]\nrustc = "SECRET_COMPILER"', '[build]\nrustc-wrapper = "SECRET_WRAPPER"', '[target.aarch64-apple-ios]\nlinker = "SECRET_LINKER"', '[env]\nRUSTC_WORKSPACE_WRAPPER = { value = "SECRET_WRAPPER", force = true }', '[env]\n"CC_aarch64-apple-ios" = "SECRET_COMPILER"', 'include = ["SECRET_CONFIG"]']
        for content in configurations:
            with self.subTest(content=content):
                (self.root / '.cargo/config.toml').write_text(content)
                with self.assertRaisesRegex(self.p.ProvenanceError, 'unsupported.*configuration') as raised:
                    self.capture()
                self.assertNotIn('SECRET_', str(raised.exception))

    def test_cargo_home_and_ancestor_compiler_configurations_are_rejected(self):
        home = self.root / 'cargo-home'
        home.mkdir()
        (home / 'config.toml').write_text('[build]\nrustc-wrapper = "SECRET"')
        with patch.dict('os.environ', {'CARGO_HOME': str(home)}):
            with self.assertRaisesRegex(self.p.ProvenanceError, 'configuration'):
                self.capture()
        (self.root / '.cargo/config.toml').write_text('[env]\nTARGET_CC = "SECRET"')
        nested = self.root / 'nested'
        nested.mkdir()
        with self.assertRaisesRegex(self.p.ProvenanceError, 'configuration'):
            self.p.capture(nested, 'native', 'release', 'device')


class SimulatorEntitlements(unittest.TestCase):
    # Actual 346-byte __TEXT,__entitlements payload from the failed Xcode 27 build;
    # codesign's actual signature plist was <dict></dict>. No xcent is an input.
    ACTUAL_SECTION = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>application-identifier</key>
\t<string>com.fqapp.fqapp</string>
\t<key>keychain-access-groups</key>
\t<array>
\t\t<string>com.fqapp.fqapp</string>
\t</array>
</dict>
</plist>
'''

    def setUp(self):
        spec = importlib.util.spec_from_file_location('provenance', SCRIPT)
        self.p = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.p)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.expected = plistlib.loads(self.ACTUAL_SECTION)
        self.app = simulator_app(self.root, self.expected)
        self.binary = self.app / 'Runner'
        self.binary.write_bytes(simulator_macho(self.ACTUAL_SECTION))
        self.signature = {}
        def codesign(args, root=None):
            if '--entitlements' in args:
                return plistlib.dumps(self.signature).decode()
            return 'Signature=adhoc\nTeamIdentifier=not set'
        mock = patch.object(self.p, 'command', codesign)
        mock.start()
        self.addCleanup(mock.stop)

    def verify(self):
        return self.p.verify_adhoc_simulator(self.app, 'com.fqapp.fqapp')

    def test_actual_embedded_section_with_empty_signature_passes_and_hashes_both(self):
        result = self.verify()
        self.assertEqual(result['mode'], 'local-ad-hoc')
        self.assertEqual(result['signature_entitlements_sha256'], self.p.json_hash({}))
        self.assertEqual(result['entitlements_sha256'], self.p.json_hash(self.expected))
        import hashlib
        self.assertEqual(result['simulator_section_sha256'], hashlib.sha256(self.ACTUAL_SECTION).hexdigest())
        self.assertNotIn('com.fqapp.fqapp', json.dumps(result))

    def test_identical_signature_and_embedded_section_pass(self):
        self.signature = self.expected
        self.assertEqual(self.verify()['mode'], 'local-ad-hoc')

    def test_missing_malformed_wrong_and_extra_section_entitlements_fail(self):
        self.signature = self.expected
        values = [b'not a plist', plistlib.dumps({}), plistlib.dumps(['wrong type']),
                  plistlib.dumps(self.expected | {'application-identifier': 'TEAM.com.fqapp.fqapp'}),
                  plistlib.dumps(self.expected | {'keychain-access-groups': ['group.other']}),
                  plistlib.dumps(self.expected | {'com.apple.developer.team-identifier': 'TEAM'}),
                  plistlib.dumps(self.expected | {'com.apple.security.application-groups': ['group.other']}),
                  plistlib.dumps(self.expected | {'get-task-allow': True})]
        for value in values:
            with self.subTest(payload=value):
                self.binary.write_bytes(simulator_macho(value))
                with self.assertRaises(self.p.ProvenanceError):
                    self.verify()
        self.binary.write_bytes(simulator_macho(self.ACTUAL_SECTION, copies=0))
        with self.assertRaises(self.p.ProvenanceError):
            self.verify()

    def test_signature_extra_entitlements_or_conflicting_values_fail(self):
        for extra in ({'com.apple.developer.team-identifier': 'TEAM'}, {'com.apple.security.application-groups': ['group.other']}, {'application-identifier': 'other.app'}, {'keychain-access-groups': ['group.other']}):
            with self.subTest(extra=extra):
                self.signature = self.expected | extra
                with self.assertRaises(self.p.ProvenanceError):
                    self.verify()

    def test_macho_boundaries_duplicates_and_unsupported_format_fail_closed(self):
        original = simulator_macho(self.ACTUAL_SECTION)
        variants = [b'', original[:20], original[:100], simulator_macho(self.ACTUAL_SECTION, copies=2)]
        # Magic, CPU, command count/size, command size, section count/size/offset.
        for offset, value, fmt in [(0, 0xcafebabe, 'I'), (4, 7, 'I'), (16, 4097, 'I'), (20, 0xffffffff, 'I'), (36, 0, 'I'), (96, 100, 'I'), (144, 2**40, 'Q'), (152, 0xfffffff0, 'I'), (152, 1, 'I'), (80, 1, 'Q')]:
            changed = bytearray(original)
            struct.pack_into('<' + fmt, changed, offset, value)
            variants.append(bytes(changed))
        self.signature = self.expected
        for index, value in enumerate(variants):
            with self.subTest(index=index):
                self.binary.write_bytes(value)
                with self.assertRaises(self.p.ProvenanceError):
                    self.verify()


if __name__ == '__main__':
    unittest.main()
