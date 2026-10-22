#!/usr/bin/env python3
"""Fail-closed signed device archive verification; never accepts local/unsigned apps.

Reports contain hashes and public identity fields only. Native manifests and App
provenance must be created by the build entry point, before validation. Fixtures
exercise this contract but do not establish acceptance of an actual Apple build.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys

from collect_ios_licenses import dependency_names
import ios_artifact_provenance as build_provenance


class VerificationError(Exception):
    """An artifact did not satisfy a release requirement."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def command(args, cwd=None):
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, check=False)
    except OSError:
        raise VerificationError(f'required tool unavailable: {args[0]}') from None
    # Do not echo raw tool output: provisioning/entitlement output can contain
    # identifiers or data not intended for the public verification record.
    require(result.returncode == 0, f'{args[0]} verification command failed')
    return result.stdout + result.stderr


def sha256(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def contained(base, relative, label):
    require(isinstance(relative, str) and relative and not pathlib.Path(relative).is_absolute(), f'invalid {label} path')
    path = base / relative
    require(path.resolve().is_relative_to(base.resolve()), f'escaping {label} path')
    return path


def read_json(path, label):
    require(path.is_file(), f'missing {label}')
    try:
        result = json.loads(path.read_text())
    except (ValueError, OSError):
        raise VerificationError(f'invalid {label}') from None
    require(isinstance(result, dict), f'invalid {label}')
    return result


def read_plist(path, label):
    require(path.is_file(), f'missing {label}')
    try:
        return plistlib.loads(path.read_bytes())
    except (ValueError, plistlib.InvalidFileException):
        raise VerificationError(f'invalid {label}') from None


def command_plist(data, label):
    start = data.find(b'<?xml')
    end = data.find(b'</plist>', start)
    require(start >= 0 and end >= 0, f'invalid {label}')
    try:
        return plistlib.loads(data[start:end + len(b'</plist>')])
    except (ValueError, plistlib.InvalidFileException):
        raise VerificationError(f'invalid {label}') from None


def source_hashes(root):
    return build_provenance.source_hashes(root, 'native')


def check_native(manifest_path, root):
    manifest = read_json(manifest_path, 'native manifest')
    require(manifest.get('schema_version') == 2 and manifest.get('build_inputs'), 'missing build-time native provenance')
    require(manifest.get('profile') == 'release' and manifest.get('minimum_ios') == '16.0', 'native profile/minimum iOS mismatch')
    require(manifest.get('source_dirty') is False, 'native build requires clean source')
    commit = command(['git', 'rev-parse', 'HEAD'], root).decode().strip()
    require(re.fullmatch(r'[0-9a-f]{40}', commit) and manifest.get('source_commit') == commit, 'source commit mismatch')
    require(not command(['git', 'status', '--porcelain', '--untracked-files=normal'], root).strip(), 'verification requires clean source')
    require(manifest.get('source_sha256') == source_hashes(root), 'native source/binding content inventory mismatch')
    rust_binding = (root / 'rust/src/frb_generated.rs').read_text()
    dart_binding = (root / 'lib/src/rust/frb_generated.dart').read_text()
    rust_ids = re.findall(r'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = (-?\d+);', rust_binding)
    dart_ids = re.findall(r'int get rustContentHash => (-?\d+);', dart_binding)
    require(len(rust_ids) == 1 and rust_ids == dart_ids and "String get codegenVersion => '2.13.0';" in dart_binding, 'generated binding content IDs/version mismatch')
    for key, args in (('rustc', ['rustc', '--version']), ('cargo', ['cargo', '--version']), ('xcode', ['xcodebuild', '-version'])):
        require(manifest.get(key) and command(args, root).decode().strip() == manifest[key], f'toolchain mismatch: {key}')
    require(manifest.get('frb') == '2.13.0' and command(['flutter_rust_bridge_codegen', '--version'], root).decode().strip() == 'flutter_rust_bridge_codegen 2.13.0', 'toolchain mismatch: FRB')
    framework = manifest_path.parent / 'fqapi_core.xcframework'
    info = read_plist(framework / 'Info.plist', 'XCFramework metadata')
    entries = info.get('AvailableLibraries', [])
    require(entries and isinstance(entries, list), 'missing native slices')
    actual = []
    for entry in entries:
        variant = entry.get('SupportedPlatformVariant')
        require(entry.get('SupportedPlatform') == 'ios' and variant in (None, 'simulator') and entry.get('SupportedArchitectures') == ['arm64'], 'invalid native slice platform')
        relative = str(pathlib.PurePosixPath(entry['LibraryIdentifier']) / entry['LibraryPath'])
        path = contained(framework, relative, 'slice')
        require(path.is_file(), 'missing native slice')
        actual.append({'target': 'aarch64-apple-ios-sim' if variant == 'simulator' else 'aarch64-apple-ios', 'platform': 'simulator' if variant == 'simulator' else 'device', 'architectures': ['arm64'], 'path': relative, 'sha256': sha256(path)})
    require(manifest.get('slices') == actual and any(s['platform'] == 'device' for s in actual), 'native slice hash/metadata mismatch or device slice missing')
    require(len({s['platform'] for s in actual}) == len(actual), 'duplicate native slice')
    try:
        build_provenance.verify_native(root, manifest_path, clean=True)
    except build_provenance.ProvenanceError as error:
        raise VerificationError(str(error)) from None
    return manifest


def uuid_map(path):
    output = command(['xcrun', 'dwarfdump', '--uuid', str(path)]).decode()
    pairs = re.findall(r'UUID:\s*([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\s*\(([^)]+)\)', output)
    require(pairs and len({arch for _, arch in pairs}) == len(pairs), 'missing or duplicate UUID')
    return {arch: value.upper() for value, arch in pairs}


def archive_hashes(archive):
    result = {}
    for path in sorted(archive.rglob('*')):
        if path.is_file():
            relative = str(path.relative_to(archive))
            contained(archive, relative, 'archive')
            result[relative] = sha256(path)
    return result


def check_licenses(archive, root):
    directory = archive / 'licenses'
    inventory = read_json(directory / 'manifest.json', 'license manifest')
    require(inventory.get('status') == 'complete' and inventory.get('unresolved') == [], 'license inventory incomplete')
    expected_locks = ('pubspec.lock', 'rust/Cargo.lock', 'ios/Podfile.lock')
    require(set(inventory.get('lock_sha256', {})) == set(expected_locks), 'license dependency lock coverage incomplete')
    for name in expected_locks:
        require((root / name).is_file() and sha256(root / name) == inventory['lock_sha256'][name], 'license dependency lock mismatch')
    require(inventory.get('entries'), 'license attribution inventory empty')
    dart, rust, pods = dependency_names(root)
    expected = {'dart:' + name for name in dart} | {f'rust:{name}@{version}' for name, version in rust} | {'pod:' + name for name in pods} | {'fqapp', 'native:tiny_aes', 'flutter', 'flutter-engine'}
    components = [entry.get('component') for entry in inventory['entries']]
    require(dart and rust and pods and len(components) == len(set(components)) and set(components) == expected, 'license locked component coverage mismatch')
    for entry in inventory['entries']:
        require(entry.get('component') and entry.get('files'), 'license attribution missing')
        for item in entry['files']:
            path = contained(directory, item['path'], 'license')
            require(path.is_file() and sha256(path) == item['sha256'], 'license file hash mismatch or missing')


def verify_archive(archive, manifest_path, root, team, bundle, version, build):
    require(re.fullmatch(r'[A-Z0-9]{10}', team or '') and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle or '') and re.fullmatch(r'\d+(?:\.\d+){1,2}', version or '') and re.fullmatch(r'[1-9]\d*', build or ''), 'all real expected identity parameters are required')
    require(archive.is_dir() and archive.suffix == '.xcarchive', 'signed device xcarchive required')
    apps = list((archive / 'Products/Applications').glob('*.app'))
    require(len(apps) == 1, 'archive must contain exactly one App')
    app = apps[0]
    info = read_plist(app / 'Info.plist', 'App Info.plist')
    for key, expected in (('CFBundleIdentifier', bundle), ('CFBundleShortVersionString', version), ('CFBundleVersion', build)):
        require(info.get(key) == expected, f'App identity mismatch: {key}')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'] and info.get('MinimumOSVersion') == '16.0', 'App platform/minimum iOS mismatch')
    executable = contained(app, info.get('CFBundleExecutable'), 'executable')
    require(executable.is_file(), 'missing App executable')
    platform = command(['xcrun', 'vtool', '-show-build', str(executable)]).decode()
    require(re.findall(r'\bplatform\s+(\S+)', platform) == ['IOS'], 'App binary is not an iOS device slice')
    require(re.findall(r'\bminos\s+(\S+)', platform) == ['16.0'], 'App binary minimum iOS mismatch')
    command(['codesign', '--verify', '--deep', '--strict', str(app)])
    signing = command(['codesign', '-d', '--verbose=4', str(app)]).decode()
    require(re.findall(r'^TeamIdentifier=(.+)$', signing, re.M) == [team], 'signature team mismatch')
    require(re.search(r'^Authority=Apple (?:Distribution|Development): .+\(' + re.escape(team) + r'\)$', signing, re.M), 'missing real Apple signing authority')
    entitlements = command_plist(command(['codesign', '-d', '--entitlements', ':-', str(app)]), 'signed entitlements')
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'entitlements team mismatch')
    require(entitlements.get('application-identifier') == f'{team}.{bundle}', 'entitlements application identity mismatch')
    require(entitlements.get('get-task-allow') is False, 'distribution archive must disable get-task-allow')
    require((app / 'embedded.mobileprovision').is_file(), 'missing provisioning profile')
    profile = command_plist(command(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]), 'provisioning profile')
    require(profile.get('TeamIdentifier') == [team] and profile.get('Entitlements', {}).get('application-identifier') == f'{team}.{bundle}' and profile.get('Entitlements', {}).get('com.apple.developer.team-identifier') == team and profile.get('Entitlements', {}).get('get-task-allow') is False, 'provisioning identity mismatch')
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime.datetime) and expiration.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc), 'provisioning profile expired')
    dsym = archive / 'dSYMs' / f'{app.name}.dSYM/Contents/Resources/DWARF' / executable.name
    require(dsym.is_file(), 'missing App dSYM')
    uuids = uuid_map(executable)
    require(uuids == uuid_map(dsym) and set(uuids) == {'arm64'}, 'App/dSYM UUID or architecture mismatch')
    manifest = check_native(manifest_path, root)
    provenance = read_json(archive / 'app-provenance.json', 'App provenance')
    require(provenance.get('artifact_kind') == 'signed-device-archive' and provenance.get('configuration') == 'Release' and provenance.get('source_commit') == manifest['source_commit'] and provenance.get('native_manifest_sha256') == sha256(manifest_path) and provenance.get('executable_sha256') == sha256(executable), 'App provenance does not bind this executable/native manifest/source')
    app_inputs = provenance.get('build_inputs')
    require(provenance.get('schema_version') == 2 and isinstance(app_inputs, dict) and provenance.get('inputs_before_sha256') == build_provenance.json_hash(app_inputs) == provenance.get('inputs_after_sha256') and provenance.get('app_files_sha256') == build_provenance.file_hashes(app), 'App provenance input/resource hashes mismatch')
    require(app_inputs.get('scope') == 'app' and app_inputs.get('require_clean') is True and app_inputs.get('source_dirty') is False and app_inputs.get('profile') == 'release' and app_inputs.get('platform') == 'device' and app_inputs.get('source_commit') == manifest['source_commit'], 'App provenance source/build configuration mismatch')
    try:
        build_provenance.check_unchanged(root, app_inputs)
    except build_provenance.ProvenanceError:
        raise VerificationError('App provenance source/toolchain changed') from None
    privacy = read_plist(app / 'PrivacyInfo.xcprivacy', 'privacy manifest')
    require(isinstance(privacy.get('NSPrivacyTracking'), bool) and isinstance(privacy.get('NSPrivacyCollectedDataTypes'), list) and isinstance(privacy.get('NSPrivacyAccessedAPITypes'), list), 'invalid privacy manifest')
    require(isinstance(info.get('NSPhotoLibraryAddUsageDescription'), str) and info['NSPhotoLibraryAddUsageDescription'].strip(), 'missing photo-library usage description')
    facts = read_json(archive / 'publication-facts.json', 'publication facts')
    require(all(facts.get(key) == 'verified' for key in ('privacy', 'usage_descriptions', 'content_rights', 'encryption', 'feedback_contact')), 'publication facts unknown/unverified')
    check_licenses(archive, root)
    files = archive_hashes(archive)
    return {'schema_version': 1, 'status': 'verified-signed-device-archive', 'source_commit': manifest['source_commit'], 'team': team, 'bundle': bundle, 'version': version, 'build': build, 'dsym_uuids': uuids, 'native_manifest_sha256': sha256(manifest_path), 'archive_files_sha256': files, 'archive_tree_sha256': hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(), 'testflight_upload': 'not-performed', 'device_acceptance': 'not-performed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('archive', 'native-manifest', 'expected-team', 'expected-bundle', 'expected-version', 'expected-build', 'report'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--source-root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    archive, report = pathlib.Path(args.archive).resolve(), pathlib.Path(args.report).resolve()
    # A report cannot hash itself, and previous evidence must not be overwritten.
    if report.exists() or report.is_relative_to(archive):
        parser.error('report must be a new path outside the archive')
    try:
        result = verify_archive(archive, pathlib.Path(args.native_manifest).resolve(), args.source_root.resolve(), args.expected_team, args.expected_bundle, args.expected_version, args.expected_build)
        code = 0
    except (VerificationError, OSError, KeyError, TypeError, ValueError) as error:
        # Fail closed without exposing arbitrary plist/tool/credential content.
        result = {'schema_version': 1, 'status': 'rejected-signed-device-archive', 'reason': str(error) if isinstance(error, VerificationError) else 'invalid artifact structure or inaccessible input', 'testflight_upload': 'not-performed'}
        code = 1
    report.parent.mkdir(parents=True, exist_ok=True)
    with report.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(result['status'])
    return code


if __name__ == '__main__':
    sys.exit(main())
