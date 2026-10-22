#!/usr/bin/env python3
"""Build-time content evidence for Apple artifacts; no signing credentials stored."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import struct
import sys
import tomllib
from xml.parsers.expat import ExpatError


class ProvenanceError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ProvenanceError(message)


def command(args, root=None):
    try:
        environment = dict(os.environ)
        if args[0] == 'git':
            environment.pop('SDKROOT', None)
        result = subprocess.run(args, cwd=root, capture_output=True, check=False, env=environment)
    except OSError:
        raise ProvenanceError(f'required tool unavailable: {args[0]}') from None
    require(result.returncode == 0, f'{args[0]} provenance command failed')
    return (result.stdout + result.stderr if args[0] == 'codesign' else result.stdout).decode().strip()


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def json_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def source_hashes(root, scope='native'):
    roots = ['rust', 'native', 'lib/src/rust', '.cargo']
    names = ['flutter_rust_bridge.yaml', 'pubspec.yaml', 'pubspec.lock', 'ios/fqapi_core.podspec']
    names += [f'scripts/{n}' for n in ('build_ios_core.sh', 'build_ios_app.sh', 'ios_artifact_provenance.py', 'verify_ios_archive.py', 'collect_ios_licenses.py')]
    if scope == 'app':
        roots += ['lib', 'assets', 'ios', 'third_party']
        names += ['.dart_tool/package_config.json', '.flutter-plugins-dependencies', 'ios/Pods/Manifest.lock', 'ios/Pods/Pods.xcodeproj/project.pbxproj']
    result = {}
    for directory in roots:
        for path in sorted((root / directory).rglob('*')):
            relative = path.relative_to(root)
            if any(part in ('target', 'build', 'Pods', '.symlinks', 'ephemeral', 'xcuserdata', '.git', '__pycache__', '.last_build_id') for part in relative.parts):
                continue
            if path.is_file():
                require(path.resolve().is_relative_to(root.resolve()), 'source path escapes checkout')
                result[str(relative)] = sha256(path)
    for name in names:
        path = root / name
        if path.is_file():
            require(path.resolve().is_relative_to(root.resolve()), 'source configuration escapes checkout')
            result[name] = sha256(path)
    return dict(sorted(result.items()))


def toolchain(scope, platform):
    commands = {'rustc': ['rustc', '--version'], 'cargo': ['cargo', '--version'], 'xcode': ['xcodebuild', '-version'], 'frb': ['flutter_rust_bridge_codegen', '--version']}
    if scope == 'app':
        commands.update({'flutter': ['flutter', '--version', '--machine'], 'pod': ['pod', '--version']})
    result = {}
    for name, args in commands.items():
        executable = shutil.which(args[0])
        require(executable, f'required tool unavailable: {args[0]}')
        result[name] = {'version': command(args), 'executable_sha256': sha256(pathlib.Path(executable).resolve())}
        if name == 'flutter':
            dart = pathlib.Path(executable).resolve().parents[1] / 'bin/cache/dart-sdk/bin/dart'
            require(dart.is_file(), 'actual Dart compiler unavailable')
            result[name]['dart_executable_sha256'] = sha256(dart)
    # rustc can be a rustup proxy; bind the actual compiler as well as that proxy.
    sysroot = pathlib.Path(command(['rustc', '--print', 'sysroot']))
    compiler = sysroot / 'bin/rustc'
    require(compiler.is_file(), 'actual Rust compiler unavailable')
    result['rustc']['compiler_sha256'] = sha256(compiler)
    for sdk in (('iphoneos', 'iphonesimulator') if platform == 'all' else ('iphoneos',) if platform == 'device' else ('iphonesimulator',)):
        clang = pathlib.Path(command(['xcrun', '--sdk', sdk, '--find', 'clang']))
        require(clang.is_file(), 'SDK compiler unavailable')
        archiver = pathlib.Path(command(['xcrun', '--sdk', sdk, '--find', 'ar']))
        require(archiver.is_file(), 'SDK archiver unavailable')
        result[sdk] = {'archiver_sha256': sha256(archiver.resolve()), 'sdk_version': command(['xcrun', '--sdk', sdk, '--show-sdk-version']), 'sdk_build': command(['xcrun', '--sdk', sdk, '--show-sdk-build-version']), 'clang_sha256': sha256(clang.resolve())}
    return result


CC_MODES = {'CRATE_CC_NO_DEFAULTS', 'CC_SHELL_ESCAPED_FLAGS', 'CC_FORCE_DISABLE', 'CC_ENABLE_DEBUG_OUTPUT'}


def compiler_override(key):
    # Reject selection mechanisms we cannot bind to the executable hashes below.
    # cc-rs accepts target names with both hyphens and underscores, plus HOST/TARGET.
    return key not in CC_MODES and (key in {'RUSTC', 'RUSTDOC', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CROSS_COMPILE', 'CC_KNOWN_WRAPPER_CUSTOM'}
        or key.startswith(('CARGO_BUILD_RUSTC', 'CARGO_BUILD_RUSTDOC'))
        or re.fullmatch(r'CARGO_TARGET_.+_(LINKER|RUNNER)', key)
        or re.fullmatch(r'(?:(?:HOST|TARGET)_)?(?:CC|CXX|AR|RANLIB)(?:_.+)?', key))


def cargo_configurations(root):
    cargo_home = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
    directories = [('checkout', root.resolve() / '.cargo'), ('cargo-home', cargo_home)]
    directories += [(f'ancestor-{depth}/.cargo', directory / '.cargo') for depth, directory in enumerate(root.resolve().parents)]
    return [(f'{label}/{name}', directory / name) for label, directory in directories for name in ('config', 'config.toml') if (directory / name).is_file()]


def validate_build_overrides(root):
    for key in os.environ:
        # Even an empty high-priority cc variable can shadow our pinned selector.
        require(not compiler_override(key), 'unsupported native compiler override')
    for _, path in cargo_configurations(root):
        try:
            config = tomllib.loads(path.read_text())
        except (OSError, ValueError):
            raise ProvenanceError('invalid Cargo build configuration') from None
        build = config.get('build', {})
        # Cargo [env] can force tool selection (including PATH/rustup/xcrun) after
        # preflight. Keep that entire injection mechanism outside this interface.
        require(not config.get('env') and 'include' not in config,
                'unsupported Cargo build configuration')
        require(isinstance(build, dict) and not any(key in build for key in ('rustc', 'rustdoc', 'rustc-wrapper', 'rustc-workspace-wrapper')),
                'unsupported Cargo compiler configuration')
        target = config.get('target', {})
        require(isinstance(target, dict) and all(isinstance(value, dict) and not any(key in value for key in ('linker', 'runner')) for value in target.values()),
                'unsupported Cargo target compiler configuration')


def environment_hashes():
    # Only hashes of build-affecting overrides, never their possibly secret values.
    exact = {'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTUP_TOOLCHAIN', 'DEVELOPER_DIR', 'CARGO_HOME', 'RUSTUP_HOME', 'PATH', 'FLUTTER_ROOT', 'DART_DEFINES'} | CC_MODES
    # cc-rs 1.4.7 combines plain, HOST/TARGET and both spellings of target flags.
    # Hash every variant, including host build dependencies, without values in logs.
    flags = r'(?:(?:HOST|TARGET)_)?(?:CFLAGS|CPPFLAGS|CXXFLAGS|LDFLAGS|ARFLAGS|RANLIBFLAGS|CXXSTDLIB)(?:_.+)?'
    return {key: hashlib.sha256(value.encode()).hexdigest() for key, value in sorted(os.environ.items()) if key in exact or re.fullmatch(flags, key) or key.startswith(('CARGO_TARGET_', 'CARGO_PROFILE_')) and key not in ('CARGO_TARGET_DIR', 'CARGO_PROFILE_RELEASE_STRIP')}


def capture(root, scope, profile, platform, clean=False):
    validate_build_overrides(root)
    commit = command(['git', 'rev-parse', 'HEAD'], root)
    require(re.fullmatch(r'[0-9a-f]{40}', commit), 'source commit unavailable')
    dirty = bool(command(['git', 'status', '--porcelain', '--untracked-files=normal'], root))
    require(not clean or not dirty, 'final artifact requires clean committed source')
    external = {label: sha256(path) for label, path in cargo_configurations(root) if not label.startswith('checkout/')}
    diff_hash = hashlib.sha256(command(['git', 'diff', '--binary', 'HEAD'], root).encode()).hexdigest()
    return {'source_diff_sha256': diff_hash, 'schema_version': 2, 'scope': scope, 'profile': profile, 'platform': platform, 'minimum_ios': '16.0', 'source_commit': commit, 'source_dirty': dirty, 'require_clean': clean, 'source_sha256': source_hashes(root, scope), 'tools': toolchain(scope, platform), 'environment_sha256': environment_hashes(), 'external_configuration_sha256': external, 'build_configuration': {'minimum_ios': '16.0', 'architectures': ['arm64'], 'rust_release_strip': 'none', 'cargo_locked': True}}


def check_unchanged(root, before):
    after = capture(root, before['scope'], before['profile'], before['platform'], before['require_clean'])
    require(before == after, 'source/toolchain/build configuration changed during build')
    return after


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def native_slices(framework, platform):
    info = plistlib.loads((framework / 'Info.plist').read_bytes())
    result = []
    for entry in info.get('AvailableLibraries', []):
        variant = entry.get('SupportedPlatformVariant')
        require(entry.get('SupportedPlatform') == 'ios' and entry.get('SupportedArchitectures') == ['arm64'] and variant in (None, 'simulator'), 'invalid XCFramework slice')
        relative = pathlib.Path(entry['LibraryIdentifier']) / entry['LibraryPath']
        path = framework / relative
        require(not relative.is_absolute() and path.resolve().is_relative_to(framework.resolve()) and path.is_file(), 'invalid XCFramework library path')
        result.append({'platform': 'simulator' if variant else 'device', 'target': 'aarch64-apple-ios-sim' if variant else 'aarch64-apple-ios', 'architectures': ['arm64'], 'path': str(relative), 'sha256': sha256(path)})
    expected = {'device', 'simulator'} if platform == 'all' else {platform}
    require(len(result) == len(expected) and {s['platform'] for s in result} == expected, 'XCFramework slice coverage mismatch')
    return result


def native_manifest(root, before, framework, codegen):
    check_unchanged(root, before)
    value = dict(before)
    value.update({'frb': '2.13.0', 'codegen': codegen, 'rustc': before['tools']['rustc']['version'], 'cargo': before['tools']['cargo']['version'], 'xcode': before['tools']['xcode']['version'], 'inputs_before_sha256': json_hash(before), 'inputs_after_sha256': json_hash(before), 'build_inputs': before, 'slices': native_slices(framework, before['platform']), 'xcframework_info_sha256': sha256(framework / 'Info.plist')})
    return value


def verify_native(root, manifest_path, clean=False):
    manifest = load(manifest_path)
    require(manifest.get('schema_version') == 2 and manifest.get('build_inputs'), 'missing build-time native provenance')
    before = manifest['build_inputs']
    require(manifest.get('inputs_before_sha256') == json_hash(before) == manifest.get('inputs_after_sha256'), 'native build input evidence mismatch')
    require(not clean or not manifest.get('source_dirty'), 'native artifact requires clean source')
    require(not clean or manifest.get('codegen') == 'generated', 'final artifact requires freshly generated bindings')
    check_unchanged(root, before)
    for key in ('source_commit', 'source_dirty', 'source_sha256', 'profile', 'platform', 'tools', 'build_configuration'):
        require(manifest.get(key) == before.get(key), 'native manifest inputs inconsistent')
    framework = manifest_path.parent / 'fqapi_core.xcframework'
    require(manifest.get('slices') == native_slices(framework, manifest['platform']) and manifest.get('xcframework_info_sha256') == sha256(framework / 'Info.plist'), 'native artifact content changed')
    return manifest


def inspect_app(app, platform, bundle, version, build):
    require((app / 'Info.plist').is_file(), 'App artifact missing Info.plist')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    for key, expected in (('CFBundleIdentifier', bundle), ('CFBundleShortVersionString', version), ('CFBundleVersion', build), ('MinimumOSVersion', '16.0')):
        require(info.get(key) == expected, 'App identity/minimum iOS mismatch')
    require(info.get('CFBundleSupportedPlatforms') == (['iPhoneOS'] if platform == 'device' else ['iPhoneSimulator']), 'App platform mismatch')
    executable = app / info['CFBundleExecutable']
    require(executable.is_file() and executable.resolve().is_relative_to(app.resolve()), 'App executable missing or invalid')
    output = command(['xcrun', 'vtool', '-show-build', str(executable)])
    require(re.findall(r'\bplatform\s+(\S+)', output) == (['IOS'] if platform == 'device' else ['IOSSIMULATOR']) and re.findall(r'\bminos\s+(\S+)', output) == ['16.0'], 'App Mach-O platform/minimum iOS mismatch')
    require(command(['xcrun', 'lipo', '-archs', str(executable)]) == 'arm64', 'App architecture mismatch')
    symbols = command(['xcrun', 'nm', '-gU', str(executable)])
    require('frb_get_rust_content_hash' in symbols and 'frb_pde_ffi_dispatcher_primary' in symbols, 'App FRB entry symbols missing')
    return executable


def file_hashes(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_file():
            require(path.resolve().is_relative_to(directory.resolve()), 'artifact path escapes archive')
            result[str(path.relative_to(directory))] = sha256(path)
    return result


def dsym_evidence(app, executable):
    archive = app.parents[2]
    dsym = archive / 'dSYMs' / f'{app.name}.dSYM/Contents/Resources/DWARF' / executable.name
    require(dsym.is_file(), 'missing App dSYM')
    def uuids(path):
        matches = re.findall(r'UUID:\s*([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\s*\(([^)]+)\)', command(['xcrun', 'dwarfdump', '--uuid', str(path)]))
        require(matches and len({arch for _, arch in matches}) == len(matches), 'missing/duplicate dSYM UUID')
        return {arch: value.upper() for value, arch in matches}
    actual = uuids(executable)
    require(actual == uuids(dsym) and set(actual) == {'arm64'}, 'App/dSYM UUID mismatch')
    return {'uuids': actual, 'sha256': sha256(dsym)}


def simulator_entitlement_section(executable):
    """Read the signed thin arm64 Mach-O, never an intermediate .xcent file."""
    with executable.open('rb') as stream:
        length = os.fstat(stream.fileno()).st_size
        header = stream.read(32)
        require(len(header) == 32, 'invalid simulator Mach-O header')
        magic, cpu, _, kind, count, size, _, _ = struct.unpack('<8I', header)
        require(magic == 0xfeedfacf and cpu == 0x100000c and kind == 2,
                'unsupported simulator Mach-O format')
        require(0 < count <= 4096 and count * 8 <= size <= 16 * 1024 * 1024 and 32 + size <= length,
                'invalid simulator Mach-O command bounds')
        commands = stream.read(size)
        require(len(commands) == size, 'truncated simulator Mach-O commands')
        position, matches = 0, []
        for _ in range(count):
            require(position + 8 <= size, 'invalid simulator Mach-O command bounds')
            command_id, command_size = struct.unpack_from('<II', commands, position)
            require(command_size >= 8 and command_size % 8 == 0 and position + command_size <= size,
                    'invalid simulator Mach-O command size')
            if command_id == 0x19:  # LC_SEGMENT_64, followed by section_64 records.
                require(command_size >= 72, 'invalid simulator Mach-O segment')
                segment = commands[position + 8:position + 24].rstrip(b'\0')
                file_offset, file_size = struct.unpack_from('<QQ', commands, position + 40)
                section_count = struct.unpack_from('<I', commands, position + 64)[0]
                require(command_size == 72 + section_count * 80 and file_offset + file_size <= length,
                        'invalid simulator Mach-O section bounds')
                for index in range(section_count):
                    section = position + 72 + index * 80
                    name = commands[section:section + 16].rstrip(b'\0')
                    owner = commands[section + 16:section + 32].rstrip(b'\0')
                    if segment == b'__TEXT' and name == b'__entitlements':
                        section_size, offset = struct.unpack_from('<QI', commands, section + 40)
                        flags = struct.unpack_from('<I', commands, section + 64)[0]
                        require(owner == segment and flags & 0xff == 0 and 0 < section_size <= 1024 * 1024
                                and offset >= 32 + size and file_offset <= offset
                                and offset + section_size <= file_offset + file_size,
                                'invalid simulator entitlement section bounds')
                        matches.append((offset, section_size))
            position += command_size
        require(position == size and len(matches) == 1, 'missing or duplicate simulator entitlement section')
        offset, section_size = matches[0]
        stream.seek(offset)
        payload = stream.read(section_size)
        require(len(payload) == section_size, 'truncated simulator entitlement section')
        return payload


def entitlement_plist(payload):
    class UniqueKeys(dict):
        def __setitem__(self, key, value):
            require(key not in self, 'duplicate simulator entitlement key')
            super().__setitem__(key, value)
    require(len(payload) <= 1024 * 1024, 'simulator entitlement plist too large')
    try:
        value = plistlib.loads(payload, dict_type=UniqueKeys)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        raise ProvenanceError('invalid simulator entitlement plist') from None
    require(isinstance(value, dict), 'invalid simulator entitlement dictionary')
    return value


def verify_adhoc_simulator(app, bundle):
    command(['codesign', '--verify', '--deep', '--strict', str(app)])
    identity = command(['codesign', '-d', '--verbose=4', str(app)])
    require(re.search(r'^Signature=adhoc$', identity, re.M), 'simulator requires local ad-hoc signature')
    require(re.search(r'^TeamIdentifier=not set$', identity, re.M), 'simulator ad-hoc signature must not use a team')
    output = command(['codesign', '-d', '--entitlements', ':-', str(app)])
    start, end = output.find('<?xml'), output.find('</plist>')
    require(start >= 0 and end > start, 'simulator Keychain entitlements missing')
    signature = entitlement_plist(output[start:end + len('</plist>')].encode())
    name = plistlib.loads((app / 'Info.plist').read_bytes()).get('CFBundleExecutable')
    require(isinstance(name, str) and name and '/' not in name and name not in ('.', '..'), 'invalid simulator executable name')
    executable = app / name
    require(executable.resolve().is_relative_to(app.resolve()), 'simulator executable escapes App')
    section = simulator_entitlement_section(executable)
    entitlements = entitlement_plist(section)
    require(set(entitlements) == {'application-identifier', 'keychain-access-groups'}, 'unexpected simulator entitlement keys')
    require(entitlements.get('application-identifier') == bundle, 'simulator application identifier must equal bundle without team prefix')
    require(entitlements.get('keychain-access-groups') == [bundle], 'simulator Keychain group must be app-scoped without team prefix')
    require(signature == {} or signature == entitlements, 'simulator signature entitlements conflict with embedded section')
    return {'mode': 'local-ad-hoc', 'entitlements_sha256': json_hash(entitlements),
            'signature_entitlements_sha256': json_hash(signature),
            'simulator_section_sha256': hashlib.sha256(section).hexdigest()}


def finalize(root, before, app, manifest_path, output, kind, bundle, version, build):
    final = kind != 'adhoc-local-simulator'
    require(before.get('scope') == 'app' and before.get('profile') == ('release' if final else 'debug') and before.get('platform') == ('device' if final else 'simulator') and (not final or before.get('require_clean') is True), 'artifact kind does not match build inputs')
    check_unchanged(root, before)
    manifest = verify_native(root, manifest_path, final)
    require(manifest['source_commit'] == before['source_commit'] and manifest['profile'] == before['profile'] and manifest['platform'] == before['platform'], 'App/native source/configuration mismatch')
    executable = inspect_app(app, before['platform'], bundle, version, build)
    signing = verify_adhoc_simulator(app, bundle) if not final else {'mode': 'team-signature-pending' if kind == 'signed-device-archive' else 'disabled'}
    symbols = dsym_evidence(app, executable) if final else {'status': 'not-required-for-debug-simulator'}
    xcode_arguments = load(output / 'build-command.json')
    require(isinstance(xcode_arguments, list) and all(isinstance(value, str) for value in xcode_arguments), 'invalid recorded Xcode arguments')
    provenance = {'schema_version': 2, 'artifact_kind': kind, 'configuration': 'Release' if before['profile'] == 'release' else 'Debug', 'source_commit': before['source_commit'], 'source_dirty': before['source_dirty'], 'native_manifest_sha256': sha256(manifest_path), 'executable_sha256': sha256(executable), 'app_files_sha256': file_hashes(app), 'inputs_before_sha256': json_hash(before), 'inputs_after_sha256': json_hash(before), 'build_inputs': before, 'code_signing_allowed': kind != 'unsigned-local-device', 'dsym': symbols, 'signing': signing, 'xcode_arguments': xcode_arguments}
    save(output / 'app-provenance.json', provenance)
    outcome = {'schema_version': 2, 'status': 'built-signed-device-archive-pending-release-verification' if kind == 'signed-device-archive' else 'verified-' + kind, 'source_commit': before['source_commit'], 'source_dirty': before['source_dirty'], 'version': version, 'build': build, 'bundle': bundle, 'signing': 'pending-release-verification' if kind == 'signed-device-archive' else 'verified-local-ad-hoc' if not final else 'disabled-not-verified', 'device_installation': 'not-performed', 'device_acceptance': 'not-performed', 'testflight_upload': 'not-performed', 'publication_facts': 'unknown-release-blocker', 'licenses': 'not-collected-release-blocker'}
    save(output / 'outcome.json', outcome)
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('preflight')
    capture_parser = sub.add_parser('capture')
    capture_parser.add_argument('--scope', choices=['native', 'app'], required=True)
    capture_parser.add_argument('--profile', choices=['debug', 'release'], required=True)
    capture_parser.add_argument('--platform', choices=['device', 'simulator', 'all'], required=True)
    capture_parser.add_argument('--clean', action='store_true')
    capture_parser.add_argument('--output', type=pathlib.Path, required=True)
    native_parser = sub.add_parser('native')
    native_parser.add_argument('--before', type=pathlib.Path, required=True)
    native_parser.add_argument('--framework', type=pathlib.Path, required=True)
    native_parser.add_argument('--codegen', choices=['generated', 'reused'], required=True)
    native_parser.add_argument('--output', type=pathlib.Path, required=True)
    finish_parser = sub.add_parser('finalize')
    for name in ('before', 'app', 'native-manifest', 'output'):
        finish_parser.add_argument('--' + name, type=pathlib.Path, required=True)
    finish_parser.add_argument('--kind', choices=['adhoc-local-simulator', 'unsigned-local-device', 'signed-device-archive'], required=True)
    for name in ('bundle', 'version', 'build'):
        finish_parser.add_argument('--' + name, required=True)
    check_parser = sub.add_parser('check')
    check_parser.add_argument('--before', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == 'preflight':
            validate_build_overrides(args.root)
        elif args.action == 'capture':
            save(args.output, capture(args.root, args.scope, args.profile, args.platform, args.clean))
        elif args.action == 'native':
            save(args.output, native_manifest(args.root, load(args.before), args.framework, args.codegen))
        elif args.action == 'check':
            check_unchanged(args.root, load(args.before))
        else:
            finalize(args.root, load(args.before), args.app, args.native_manifest, args.output, args.kind, args.bundle, args.version, args.build)
    except (ProvenanceError, OSError, ValueError, KeyError, TypeError) as error:
        print(str(error) if isinstance(error, ProvenanceError) else 'invalid/inaccessible provenance input', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
