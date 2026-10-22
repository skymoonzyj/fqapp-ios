#!/usr/bin/env python3
"""Install the locally built helper. Use --start only after review and checks."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--start', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    source = Path(__file__).resolve().parent
    runtime = Path.home() / 'Library/Application Support/FqappAutoRenew'
    app = Path.home() / 'Applications/Fqapp Auto Renew.app'
    built = source / 'build/Fqapp Auto Renew.app'
    agent = Path.home() / 'Library/LaunchAgents/com.fqapp.autorenew.plist'
    domain = 'gui/' + str(os.getuid())
    label = domain + '/com.fqapp.autorenew'
    assert (runtime / 'config.json').is_file() and (runtime / 'state.json').is_file()
    assert (source / 'renew.py').is_file()
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(built))
    info = plistlib.loads((built / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.fqapp.autorenew'
    assert info['FQPythonPath'] == '/usr/bin/python3'
    if app.exists() or agent.exists():
        raise SystemExit('Helper is already installed; preserve it and use an explicit reviewed update.')
    app.parent.mkdir(exist_ok=True)
    shutil.copytree(built, app)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    shutil.copy2(source / 'renew.py', runtime / 'renew.py')
    (runtime / 'renew.py').chmod(0o600)
    agent.parent.mkdir(exist_ok=True)
    configuration = {
        'Label': 'com.fqapp.autorenew',
        'ProgramArguments': [str(app / 'Contents/MacOS/FqappAutoRenew')],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'ThrottleInterval': 30,
        'ProcessType': 'Interactive',
        'LimitLoadToSessionType': 'Aqua',
        'WorkingDirectory': str(runtime),
        'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin'},
        'StandardOutPath': str(runtime / 'logs/menu.stdout.log'),
        'StandardErrorPath': str(runtime / 'logs/menu.stderr.log'),
    }
    agent.write_bytes(plistlib.dumps(configuration))
    agent.chmod(0o600)
    run('/usr/bin/plutil', '-lint', str(agent))
    if args.start:
        run('/bin/launchctl', 'enable', label)
        run('/bin/launchctl', 'bootstrap', domain, str(agent))
    report = {
        'installed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
        'app': str(app), 'launch_agent': str(agent), 'started': args.start,
        'local_codesign_verified': True,
    }
    (runtime / 'evidence/utility-install.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
