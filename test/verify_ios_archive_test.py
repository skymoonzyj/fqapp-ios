"""Contract fixtures, not a claim that a real Apple archive was verified."""
import copy
import datetime
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import sys
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/verify_ios_archive.py'
sys.path.insert(0, str(SCRIPT.parent))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ArchiveContract(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'signed archive verifier must exist')
        spec = importlib.util.spec_from_file_location('archive_verifier', SCRIPT)
        self.v = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.v)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.archive = self.root / 'Release.xcarchive'
        self.app = self.archive / 'Products/Applications/Runner.app'
        self.app.mkdir(parents=True)
        self.write('rust/src/lib.rs', b'pub fn example() {}')
        self.write('rust/src/frb_generated.rs', b'const FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = 123;')
        self.write('lib/src/rust/frb_generated.dart', b"String get codegenVersion => '2.13.0'; int get rustContentHash => 123;")
        self.write('native/core.c', b'int value;')
        self.write('flutter_rust_bridge.yaml', b'rust_input: crate::api')
        self.write('scripts/build_ios_core.sh', b'build core')
        self.write('rust/Cargo.lock', b'version = 3\n[[package]]\nname = "example"\nversion = "1.0.0"\n')
        self.write('pubspec.lock', b'packages:\n  example:\n    version: "1.0.0"\n')
        self.write('ios/Podfile.lock', b'PODS:\n  - Example (1.0.0)\n')
        self.write('build/ios-native/fqapi_core.xcframework/ios-arm64/libfqapi_core.a', b'core')
        self.plist(self.root / 'build/ios-native/fqapi_core.xcframework/Info.plist', {'AvailableLibraries': [{'LibraryIdentifier': 'ios-arm64', 'LibraryPath': 'libfqapi_core.a', 'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64']}]})
        self.info = {'CFBundleIdentifier': 'com.example.app', 'CFBundleShortVersionString': '1.0.127', 'CFBundleVersion': '132', 'CFBundleExecutable': 'Runner', 'MinimumOSVersion': '16.0', 'CFBundleSupportedPlatforms': ['iPhoneOS'], 'NSPhotoLibraryAddUsageDescription': 'Save requested images'}
        self.plist(self.app / 'Info.plist', self.info)
        (self.app / 'Runner').write_bytes(b'executable')
        (self.app / 'embedded.mobileprovision').write_bytes(b'profile')
        self.plist(self.app / 'PrivacyInfo.xcprivacy', {'NSPrivacyTracking': False, 'NSPrivacyCollectedDataTypes': [], 'NSPrivacyAccessedAPITypes': []})
        self.dsym = self.archive / 'dSYMs/Runner.app.dSYM/Contents/Resources/DWARF/Runner'
        self.dsym.parent.mkdir(parents=True)
        self.dsym.write_bytes(b'debug')
        self.manifest_path = self.root / 'build/ios-native/manifest.json'
        inputs = {str(p.relative_to(self.root)): digest(p) for folder in ('rust', 'native', 'lib/src/rust') for p in (self.root / folder).rglob('*') if p.is_file()}
        for name in ('flutter_rust_bridge.yaml', 'scripts/build_ios_core.sh'):
            inputs[name] = digest(self.root / name)
        self.manifest = {'profile': 'release', 'minimum_ios': '16.0', 'source_commit': 'a' * 40, 'source_dirty': False, 'rustc': 'rustc 1.99.1', 'cargo': 'cargo 1.99.1', 'xcode': 'Xcode 27.0\nBuild version 18A123', 'frb': '2.13.0', 'codegen': 'generated', 'source_sha256': inputs, 'slices': [{'platform': 'device', 'architectures': ['arm64'], 'path': 'ios-arm64/libfqapi_core.a', 'sha256': digest(self.root / 'build/ios-native/fqapi_core.xcframework/ios-arm64/libfqapi_core.a')}]}
        self.json(self.manifest_path, self.manifest)
        self.provenance = {'artifact_kind': 'signed-device-archive', 'source_commit': 'a' * 40, 'native_manifest_sha256': digest(self.manifest_path), 'executable_sha256': digest(self.app / 'Runner'), 'configuration': 'Release'}
        self.json(self.archive / 'app-provenance.json', self.provenance)
        self.facts = {'privacy': 'verified', 'usage_descriptions': 'verified', 'content_rights': 'verified', 'encryption': 'verified', 'feedback_contact': 'verified'}
        self.json(self.archive / 'publication-facts.json', self.facts)
        self.write('Release.xcarchive/licenses/app-LICENSE.txt', b'license')
        self.licenses = {'status': 'complete', 'lock_sha256': {n: digest(self.root / n) for n in ('pubspec.lock', 'rust/Cargo.lock', 'ios/Podfile.lock')}, 'entries': [{'component': 'dart:example', 'files': [{'path': 'app-LICENSE.txt', 'sha256': digest(self.archive / 'licenses/app-LICENSE.txt')}]}], 'unresolved': []}
        for name in ('rust:example@1.0.0', 'pod:Example', 'fqapp', 'native:tiny_aes', 'flutter', 'flutter-engine'):
            self.licenses['entries'].append(dict(self.licenses['entries'][0], component=name))
        self.json(self.archive / 'licenses/manifest.json', self.licenses)
        self.entitlements = {'com.apple.developer.team-identifier': 'ABCDE12345', 'application-identifier': 'ABCDE12345.com.example.app', 'get-task-allow': False}
        self.profile = {'TeamIdentifier': ['ABCDE12345'], 'ExpirationDate': datetime.datetime(2099, 1, 1), 'Entitlements': copy.deepcopy(self.entitlements)}
        self.outputs = {}
        self.command_patch = patch.object(self.v, 'command', self.command)
        self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        self.helper_command = patch.object(self.v.build_provenance, 'command', lambda args, root=None: self.command(args, root).decode().strip())
        self.helper_command.start()
        self.addCleanup(self.helper_command.stop)
        tools = {key: {'version': self.manifest[key], 'executable_sha256': 'a' * 64} for key in ('rustc', 'cargo', 'xcode')}
        self.helper_tools = patch.object(self.v.build_provenance, 'toolchain', return_value=tools)
        self.helper_tools.start()
        self.addCleanup(self.helper_tools.stop)
        before = self.v.build_provenance.capture(self.root, 'native', 'release', 'device', True)
        self.manifest.update(before)
        self.manifest.update({'build_inputs': before, 'inputs_before_sha256': self.v.build_provenance.json_hash(before), 'inputs_after_sha256': self.v.build_provenance.json_hash(before), 'xcframework_info_sha256': digest(self.root / 'build/ios-native/fqapi_core.xcframework/Info.plist')})
        self.manifest['slices'][0]['target'] = 'aarch64-apple-ios'
        self.json(self.manifest_path, self.manifest)
        app_before = self.v.build_provenance.capture(self.root, 'app', 'release', 'device', True)
        self.provenance.update({'schema_version': 2, 'build_inputs': app_before, 'inputs_before_sha256': self.v.build_provenance.json_hash(app_before), 'inputs_after_sha256': self.v.build_provenance.json_hash(app_before), 'app_files_sha256': self.v.build_provenance.file_hashes(self.app), 'native_manifest_sha256': digest(self.manifest_path)})
        self.json(self.archive / 'app-provenance.json', self.provenance)

    def write(self, name, content):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)

    def plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def json(self, path, value):
        path.write_text(json.dumps(value))

    def command(self, args, cwd=None):
        key = tuple(args)
        if key in self.outputs:
            result = self.outputs[key]
            if isinstance(result, Exception):
                raise result
            return result
        if args[:4] == ['codesign', '--verify', '--deep', '--strict']:
            return b''
        if args[:3] == ['codesign', '-d', '--entitlements']:
            return plistlib.dumps(self.entitlements)
        if args[:3] == ['codesign', '-d', '--verbose=4']:
            return b'TeamIdentifier=ABCDE12345\nAuthority=Apple Distribution: Example (ABCDE12345)\n'
        if args[:3] == ['security', 'cms', '-D']:
            return plistlib.dumps(self.profile)
        if args[:3] == ['xcrun', 'dwarfdump', '--uuid']:
            return b'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) artifact\n'
        if args[:3] == ['xcrun', 'vtool', '-show-build']:
            return b'platform IOS\nminos 16.0\n'
        if args == ['git', 'diff', '--binary', 'HEAD']:
            return b''
        if args == ['git', 'rev-parse', 'HEAD']:
            return b'a' * 40
        if args == ['git', 'status', '--porcelain', '--untracked-files=normal']:
            return b''
        tools = {('rustc', '--version'): b'rustc 1.99.1', ('cargo', '--version'): b'cargo 1.99.1', ('xcodebuild', '-version'): b'Xcode 27.0\nBuild version 18A123', ('flutter_rust_bridge_codegen', '--version'): b'flutter_rust_bridge_codegen 2.13.0'}
        if key in tools:
            return tools[key]
        raise AssertionError(f'unexpected external command: {args}')

    def verify(self):
        return self.v.verify_archive(self.archive, self.manifest_path, self.root, 'ABCDE12345', 'com.example.app', '1.0.127', '132')

    def reject(self, pattern):
        with self.assertRaisesRegex(self.v.VerificationError, pattern):
            self.verify()

    def test_consistent_fixture_records_signed_artifact_hashes_and_uuid(self):
        result = self.verify()
        self.assertEqual(result['status'], 'verified-signed-device-archive')
        self.assertEqual(result['dsym_uuids'], {'arm64': '12345678-1234-1234-1234-123456789ABC'})
        self.assertEqual(result['native_manifest_sha256'], digest(self.manifest_path))

    def test_wrong_identity_version_build_and_platform_rejected(self):
        for key, value in [('CFBundleIdentifier', 'other.app'), ('CFBundleShortVersionString', '1.0'), ('CFBundleVersion', '1'), ('CFBundleSupportedPlatforms', ['iPhoneSimulator'])]:
            with self.subTest(key=key):
                modified = dict(self.info, **{key: value})
                self.plist(self.app / 'Info.plist', modified)
                self.reject('identity|platform')
        self.plist(self.app / 'Info.plist', self.info)

    def test_actual_signature_failure_rejected_without_leaking_output(self):
        self.outputs[('codesign', '--verify', '--deep', '--strict', str(self.app))] = self.v.VerificationError('signature verification failed')
        self.reject('signature')

    def test_wrong_team_in_signed_entitlements_rejected(self):
        self.entitlements['com.apple.developer.team-identifier'] = 'WRONG12345'
        self.reject('team')

    def test_profile_app_identity_and_expiration_rejected(self):
        self.profile['Entitlements']['application-identifier'] = 'ABCDE12345.other.app'
        self.reject('provisioning')
        self.profile['Entitlements'] = copy.deepcopy(self.entitlements)
        self.profile['ExpirationDate'] = datetime.datetime(2000, 1, 1)
        self.reject('expired')

    def test_simulator_binary_rejected_even_if_plist_claims_device(self):
        self.outputs[('xcrun', 'vtool', '-show-build', str(self.app / 'Runner'))] = b'platform IOSSIMULATOR\nminos 16.0'
        self.reject('device')

    def test_missing_dsym_and_mismatched_uuid_rejected(self):
        self.outputs[('xcrun', 'dwarfdump', '--uuid', str(self.dsym))] = b'UUID: 87654321-1234-1234-1234-123456789ABC (arm64) debug'
        self.reject('UUID')
        self.dsym.unlink()
        self.reject('dSYM')

    def test_changed_and_omitted_source_inputs_rejected(self):
        self.write('native/core.c', b'changed')
        self.reject('source')
        self.write('native/core.c', b'int value;')
        self.write('rust/src/new.rs', b'new source')
        self.reject('source')

    def test_changed_generated_binding_rejected(self):
        self.write('lib/src/rust/frb_generated.dart', b'stale binding')
        self.reject('source')

    def test_changed_native_artifact_rejected(self):
        self.write('build/ios-native/fqapi_core.xcframework/ios-arm64/libfqapi_core.a', b'changed core')
        self.reject('slice')

    def test_native_plist_simulator_slice_rejected(self):
        p = self.root / 'build/ios-native/fqapi_core.xcframework/Info.plist'
        info = plistlib.loads(p.read_bytes())
        info['AvailableLibraries'][0]['SupportedPlatformVariant'] = 'simulator'
        self.plist(p, info)
        self.reject('slice')

    def test_missing_app_provenance_rejected(self):
        (self.archive / 'app-provenance.json').unlink()
        self.reject('provenance')

    def test_wrong_app_manifest_binding_rejected(self):
        self.provenance['native_manifest_sha256'] = '0' * 64
        self.json(self.archive / 'app-provenance.json', self.provenance)
        self.reject('provenance')

    def test_missing_privacy_and_unknown_publication_facts_rejected(self):
        self.facts['content_rights'] = 'unknown'
        self.json(self.archive / 'publication-facts.json', self.facts)
        self.reject('publication')
        (self.app / 'PrivacyInfo.xcprivacy').unlink()
        self.reject('privacy|App provenance')

    def test_missing_license_and_stale_lock_rejected(self):
        self.write('pubspec.lock', b'changed dependencies')
        self.reject('license|source')
        self.write('pubspec.lock', b'packages:\n  example:\n    version: "1.0.0"\n')
        (self.archive / 'licenses/app-LICENSE.txt').unlink()
        self.reject('license')

    def test_toolchain_drift_and_dirty_source_rejected(self):
        self.outputs[('rustc', '--version')] = b'rustc 1.100.0'
        self.reject('toolchain')
        self.outputs.pop(('rustc', '--version'))
        self.outputs[('git', 'status', '--porcelain', '--untracked-files=normal')] = b' M rust/src/lib.rs'
        self.reject('clean')

    def test_matching_file_hashes_do_not_hide_mismatched_frb_binding_ids(self):
        self.write('lib/src/rust/frb_generated.dart', b"String get codegenVersion => '2.13.0'; int get rustContentHash => 456;")
        self.manifest['source_sha256']['lib/src/rust/frb_generated.dart'] = digest(self.root / 'lib/src/rust/frb_generated.dart')
        self.json(self.manifest_path, self.manifest)
        self.provenance['native_manifest_sha256'] = digest(self.manifest_path)
        self.json(self.archive / 'app-provenance.json', self.provenance)
        self.reject('binding')

    def test_license_inventory_must_cover_every_locked_component(self):
        self.licenses['entries'] = self.licenses['entries'][:1]
        self.json(self.archive / 'licenses/manifest.json', self.licenses)
        self.reject('license')

    def test_signature_authority_team_and_ad_hoc_signature_rejected(self):
        self.outputs[('codesign', '-d', '--verbose=4', str(self.app))] = b'TeamIdentifier=OTHER12345\nSignature=adhoc\n'
        self.reject('team|authority')

    def test_legacy_manifest_without_build_time_inputs_rejected(self):
        self.manifest.pop('build_inputs', None)
        self.json(self.manifest_path, self.manifest)
        self.provenance['native_manifest_sha256'] = digest(self.manifest_path)
        self.json(self.archive / 'app-provenance.json', self.provenance)
        self.reject('build-time')

    def test_app_resource_mutation_after_build_rejected(self):
        (self.app / 'unexpected-resource').write_bytes(b'changed app')
        self.reject('App provenance')

    def test_app_input_evidence_mismatch_rejected(self):
        self.provenance['inputs_after_sha256'] = '0' * 64
        self.json(self.archive / 'app-provenance.json', self.provenance)
        self.reject('App provenance')

    def test_missing_identity_parameters_rejected(self):
        with self.assertRaisesRegex(self.v.VerificationError, 'identity'):
            self.v.verify_archive(self.archive, self.manifest_path, self.root, '', 'com.example.app', '1.0.127', '132')


if __name__ == '__main__':
    unittest.main()
