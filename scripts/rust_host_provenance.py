#!/usr/bin/env python3
"""Bind a reusable host library to exact inputs, toolchain and feature set."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys


def native_environment():
    names = {'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'CC', 'CXX', 'AR', 'RANLIB'}
    names.update(name for name in os.environ if re.fullmatch(
        r'(?:(?:HOST|TARGET)_)?(?:CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|CPPFLAGS)(?:_[A-Za-z0-9_-]+)?', name))
    names.update(('CRATE_CC_NO_DEFAULTS', 'CC_FORCE_DISABLE'))
    return {name: os.environ.get(name, '') for name in sorted(names)}


def native_compiler_identity(kind, host_target, root):
    candidates = (f'{kind}_{host_target}', f'{kind}_{host_target.replace("-", "_")}',
                  f'HOST_{kind}', f'TARGET_{kind}', kind)
    selected = next((name for name in candidates if os.environ.get(name)), None)
    command = shlex.split(os.environ[selected]) if selected else ['cc' if kind == 'CC' else 'c++']
    executable = shutil.which(command[0]) if command else None
    if executable is None:
        raise ValueError(f'native compiler is unavailable: {kind}')
    version = subprocess.run([*command, '--version'], cwd=root, check=True,
                             capture_output=True, text=True, timeout=10)
    return {'selected_environment': selected, 'command': command,
            'executable': str(Path(executable).resolve()),
            'version': (version.stdout or version.stderr).strip()}


def snapshot(root, features):
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root)
    paths = git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
                'rust', 'native', '.cargo', 'flutter_rust_bridge.yaml',
                'scripts/run_rust_host_tests.sh', 'scripts/rust_host_provenance.py')
    inputs = {}
    for entry in sorted(set(filter(None, paths.split(b'\0')))):
        path = root / os.fsdecode(entry)
        inputs[os.fsdecode(entry)] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    compilers = {}
    if 'native-media-host-tests' in features:
        verbose = subprocess.check_output(['rustc', '-vV'], text=True)
        host = re.search(r'^host: (.+)$', verbose, re.MULTILINE)
        if host is None:
            raise ValueError('rustc did not report its native host target')
        compilers = {kind: native_compiler_identity(kind, host[1], root) for kind in ('CC', 'CXX')}
    return {
        'schema_version': 1,
        'source_sha': git('rev-parse', 'HEAD').decode().strip(),
        'inputs_sha256': inputs,
        'features': features,
        'rustc': subprocess.check_output(['rustc', '--version'], text=True).strip(),
        'host': f'{platform.system()}-{platform.machine()}',
        'native_compilers': compilers,
        'build_environment': {**native_environment(), **{name: os.environ.get(name, '') for name in (
            'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_BUILD_TARGET')}},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['snapshot', 'stamp', 'verify'])
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--features', default='')
    parser.add_argument('--snapshot-file', type=Path)
    args = parser.parse_args()
    features = [args.features] if args.features else []
    if features not in ([], ['native-media-host-tests']):
        parser.error('unsupported host-test features')
    root = Path(__file__).resolve().parents[1]
    stamp = Path(str(args.library) + '.provenance.json')
    try:
        current = snapshot(root, features)
        if args.action == 'snapshot':
            if args.snapshot_file is None:
                parser.error('--snapshot-file is required')
            args.snapshot_file.write_text(json.dumps(current, indent=2) + '\n')
            return 0
        if not args.library.is_file() or not args.library.stat().st_size:
            raise ValueError('missing/empty host library')
        current['library_sha256'] = hashlib.sha256(args.library.read_bytes()).hexdigest()
        if args.action == 'stamp':
            if args.snapshot_file is None:
                parser.error('--snapshot-file is required')
            before = json.loads(args.snapshot_file.read_text())
            if {k: v for k, v in current.items() if k != 'library_sha256'} != before:
                raise ValueError('source/toolchain/features changed during build')
            temporary = Path(str(stamp) + '.tmp')
            temporary.write_text(json.dumps(current, indent=2) + '\n')
            temporary.replace(stamp)
        else:
            if not stamp.is_file() or json.loads(stamp.read_text()) != current:
                raise ValueError('host library provenance mismatch or absent; rebuild without --skip-build')
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'host provenance error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
