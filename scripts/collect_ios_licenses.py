#!/usr/bin/env python3
"""Collect local iOS license texts with locked dependency coverage (Python 3.11+).

No network, package installation, or license/legal conclusions. Exit 2 indicates
unknown/missing evidence. Cargo metadata is an explicit offline input; obtain it
with cargo metadata --locked --offline --format-version 1. Output is never reused.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import sys
import tomllib
import urllib.parse
import urllib.request

LICENSE_NAME = re.compile(r'^(?:LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|UNLICENSE)(?:[._-].*)?$', re.I)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def optional_json(path):
    if path is None or not path.is_file():
        return {}
    return json.loads(path.read_text())


def dependency_names(root):
    """Read lock formats without importing SDK/package-manager internals."""
    dart = root / 'pubspec.lock'
    cargo = root / 'rust/Cargo.lock'
    pod = root / 'ios/Podfile.lock'
    dart_names = set()
    pod_names = set()
    if dart.is_file():
        text = dart.read_text()
        section = re.search(r'^packages:\s*\n(.*?)(?=^\S|\Z)', text, re.M | re.S)
        if section:
            dart_names = set(re.findall(r'^  ([A-Za-z0-9_]+):\s*$', section[1], re.M))
    rust_names = {(p['name'], p['version']) for p in tomllib.loads(cargo.read_text()).get('package', [])} if cargo.is_file() else set()
    if pod.is_file():
        section = re.search(r'^PODS:\s*\n(.*?)(?=^\S|\Z)', pod.read_text(), re.M | re.S)
        if section:
            pod_names = {name.split('/')[0] for name in re.findall(r'^  - ([^\s:(]+)', section[1], re.M)}
    return dart_names, rust_names, pod_names


def collect(root, destination, cargo_metadata=None, flutter_root=None):
    destination.mkdir(parents=True, exist_ok=False)
    entries, unresolved, locks = [], [], {}
    for name in ('pubspec.lock', 'rust/Cargo.lock', 'ios/Podfile.lock'):
        path = root / name
        if path.is_file():
            locks[name] = sha256(path)
        else:
            unresolved.append('lock:' + name)

    def add(component, paths=(), text=None):
        files = []
        for index, path in enumerate(sorted(set(paths))):
            if path.is_file():
                name = re.sub(r'[^A-Za-z0-9._-]', '_', component) + f'-{index}-{path.name}.txt'
                output = destination / name
                output.write_bytes(path.read_bytes())
                files.append({'path': name, 'sha256': sha256(output)})
        if text:
            name = re.sub(r'[^A-Za-z0-9._-]', '_', component) + '-acknowledgement.txt'
            output = destination / name
            output.write_text(text)
            files.append({'path': name, 'sha256': sha256(output)})
        if not files:
            unresolved.append(component)
        entries.append({'component': component, 'files': files})

    def licenses(path):
        return [p for p in path.iterdir() if p.is_file() and LICENSE_NAME.match(p.name)] if path.is_dir() else []

    dart_names, rust_names, pod_names = dependency_names(root)
    for ecosystem, names in (('dart', dart_names), ('rust', rust_names), ('pod', pod_names)):
        if not names:
            unresolved.append('dependency-inventory:' + ecosystem)
    config_path = root / '.dart_tool/package_config.json'
    packages = {p['name']: p for p in optional_json(config_path).get('packages', [])}
    lock_text = (root / 'pubspec.lock').read_text() if (root / 'pubspec.lock').is_file() else ''
    dart_versions = {}
    for name, body in re.findall(r'^  ([A-Za-z0-9_]+):\s*\n(.*?)(?=^  \S|^\S|\Z)', lock_text, re.M | re.S):
        version = re.search(r'^    version: [\"\']?([^\"\'\s]+)', body, re.M)
        if version:
            dart_versions[name] = version[1]
    for name in sorted(dart_names):
        package = packages.get(name)
        paths = []
        if package:
            uri = urllib.parse.urlsplit(package['rootUri'])
            if uri.scheme == 'file' and not uri.netloc:
                package_root = pathlib.Path(urllib.request.url2pathname(uri.path))
            elif not uri.scheme and not uri.netloc:
                package_root = config_path.parent / urllib.parse.unquote(package['rootUri'])
            else:
                package_root = None
            if package_root:
                manifest = package_root / 'pubspec.yaml'
                resolved_version = re.search(r'^version: [\"\']?([^\"\'\s]+)', manifest.read_text(), re.M) if manifest.is_file() else None
                if resolved_version and dart_versions.get(name) == resolved_version[1]:
                    paths = licenses(package_root)
        add('dart:' + name, paths)
    metadata = optional_json(cargo_metadata)
    rust_packages = {(p['name'], p['version']): p for p in metadata.get('packages', [])}
    for name, version in sorted(rust_names):
        package = rust_packages.get((name, version))
        paths = []
        if package:
            directory = pathlib.Path(package['manifest_path']).parent
            paths = licenses(directory)
            if package.get('license_file'):
                declared = (directory / package['license_file']).resolve()
                if declared.is_relative_to(directory.resolve()):
                    paths.append(declared)
        add(f'rust:{name}@{version}', paths)
    acknowledgements = root / 'ios/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist'
    pod_texts = {}
    installed_lock = root / 'ios/Pods/Manifest.lock'
    requested_lock = root / 'ios/Podfile.lock'
    if acknowledgements.is_file() and installed_lock.is_file() and requested_lock.is_file() and sha256(installed_lock) == sha256(requested_lock):
        for item in plistlib.loads(acknowledgements.read_bytes()).get('PreferenceSpecifiers', []):
            if item.get('Title') and item.get('FooterText'):
                pod_texts[item['Title']] = item['FooterText']
    for name in sorted(pod_names):
        add('pod:' + name, text=pod_texts.get(name))
    add('fqapp', [root / 'LICENSE'])
    add('native:tiny_aes', [root / 'native/third_party/tiny_aes/unlicense.txt'])
    add('flutter', [flutter_root / 'LICENSE'] if flutter_root else [])
    add('flutter-engine', [flutter_root / 'bin/cache/LICENSE.engine'] if flutter_root else [])
    result = {'schema_version': 1, 'status': 'incomplete' if unresolved else 'complete', 'lock_sha256': locks, 'entries': entries, 'unresolved': sorted(set(unresolved)), 'scope': 'local dependency license text inventory; content, asset and distribution rights require separate review'}
    (destination / 'manifest.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--cargo-metadata', type=pathlib.Path)
    parser.add_argument('--flutter-root', type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = collect(args.source_root.resolve(), args.output.resolve(), args.cargo_metadata, args.flutter_root)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        print('license inventory failed; destination must be new and inputs valid', file=sys.stderr)
        return 1
    print(f"license inventory: {result['status']}; unresolved: {len(result['unresolved'])}")
    return 0 if result['status'] == 'complete' else 2


if __name__ == '__main__':
    sys.exit(main())
