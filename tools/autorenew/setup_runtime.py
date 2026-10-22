#!/usr/bin/env python3
"""Initialize a private runtime from explicit local inputs; no account/device calls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat

import renew

DEFAULT_HOME = Path.home() / 'Library/Application Support/FqappAutoRenew'
PROJECT_FILES = ('main.c', 'ProfilePreparation.entitlements',
                 'ProfilePreparation.xcodeproj/project.pbxproj',
                 'ProfilePreparation.xcodeproj/xcshareddata/xcschemes/ProfilePreparation.xcscheme')


def inventory(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError('source_app must be a regular unsigned .app directory')
    files = {}
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not (path.is_dir() or stat.S_ISREG(path.stat().st_mode)):
            raise ValueError('source_app contains a symlink or special file')
        if path.is_file():
            if len(files) >= 10000 or path.stat().st_size >= 2 * 1024 ** 3:
                raise ValueError('source_app exceeds the engine file limits')
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            files[path.relative_to(app).as_posix()] = {
                'sha256': digest.hexdigest(), 'mode': stat.S_IMODE(path.stat().st_mode)}
    return files


def bootstrap(config_path, home=DEFAULT_HOME, installed_expiry=None):
    home = Path(home)
    if not home.is_absolute() or home.exists() or home.is_symlink():
        raise ValueError('Runtime must be an absolute, new directory; existing runtimes are never reset')
    cfg = renew.read_json(config_path, 'config_invalid')
    expiry = installed_expiry or cfg.pop('installed_expires_at', None)
    # This is supplied evidence of the installed app, not a new installation receipt.
    renew.parse_time(expiry)
    cfg.pop('installed_expires_at', None)
    cfg['source_manifest'] = str(home / 'source-manifest.json')
    renew.validate_config(cfg)
    source = Path(cfg['source_app'])
    project = Path(cfg['provisioning_project'])
    if project.name != 'ProfilePreparation.xcodeproj' or project.is_symlink():
        raise ValueError('Use the minimal ProfilePreparation.xcodeproj from prepare_project.rb')
    manifest = {key: cfg[key] for key in ('bundle_id', 'version', 'build')}
    manifest['files'] = inventory(source)
    renew.verify_source(source, manifest, cfg)
    # Preserve the existing engine's supported Flutter payload boundary.
    if len(list((source / 'Frameworks').glob('*.framework'))) != 13:
        raise ValueError('This engine supports the existing 13-framework fqapp payload only')
    if not (source / 'Runner').is_file() or not (source / 'Frameworks/App.framework/App').is_file():
        raise ValueError('Runner and App.framework executables are required')
    project_root = project.parent
    project_inputs = {}
    for relative in PROJECT_FILES:
        path = project_root / relative
        if any(p.is_symlink() for p in (path, *path.parents) if p != project_root and project_root in p.parents):
            raise ValueError('Provisioning project inputs must not contain symlinks')
        if not path.is_file() or path.stat().st_size > 2 * 1024 ** 2:
            raise ValueError('Missing or oversized minimal provisioning project input: ' + relative)
        project_inputs[relative] = path.read_bytes()
    source_real, project_real, home_real = source.resolve(), project_root.resolve(), home.resolve()
    if home_real == source_real or source_real in home_real.parents or home_real == project_real or project_real in home_real.parents:
        raise ValueError('Runtime must be outside the source app and provisioning input directory')

    old_umask = os.umask(0o077)
    try:
        home.mkdir(parents=True, mode=0o700, exist_ok=False)
        for name in ('source', 'logs', 'runs', 'evidence', 'profile-preparation'):
            (home / name).mkdir(mode=0o700)
        destination = home / 'source/Runner.app'
        shutil.copytree(source, destination, copy_function=shutil.copy2)
        renew.verify_source(destination, manifest, cfg)
        if inventory(source) != manifest['files']:
            raise ValueError('Source changed while copying; runtime initialization is incomplete')
        for relative, data in project_inputs.items():
            if (project_root / relative).read_bytes() != data:
                raise ValueError('Provisioning project changed while copying')
            target = home / 'profile-preparation' / relative
            target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o600)
        cfg['source_app'] = str(destination)
        cfg['provisioning_project'] = str(home / 'profile-preparation/ProfilePreparation.xcodeproj')
        state = {
            'schema_version': 1, 'status': 'healthy', 'message': '本机配置已初始化，等待首次检查',
            'paused': False, 'installed_expires_at': expiry,
            'last_check_at': None, 'last_success_at': None, 'next_check_at': None,
            'error_code': None, 'notification_id': None, 'last_run_dir': None,
        }
        renew.validate_state(state)
        renew.atomic_json(home / 'source-manifest.json', manifest)
        renew.atomic_json(home / 'config.json', cfg)
        renew.atomic_json(home / 'state.json', state)
        return {'runtime': str(home), 'verified_payload_files': len(manifest['files']),
                'installed_expiry_supplied_locally': expiry, 'device_contacted': False}
    finally:
        os.umask(old_umask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='Explicit local config.json input')
    parser.add_argument('--home', type=Path, default=DEFAULT_HOME,
                        help='New runtime directory; GUI/installer use the default path')
    parser.add_argument('--installed-expires-at', help='Verified installed profile expiry, UTC ISO date ending Z')
    args = parser.parse_args()
    try:
        print(json.dumps(bootstrap(args.config, args.home, args.installed_expires_at), ensure_ascii=False))
    except (OSError, ValueError, renew.RenewalError) as error:
        parser.exit(1, 'Setup stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
