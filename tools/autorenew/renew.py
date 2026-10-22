#!/usr/bin/env python3
"""Private, stdlib-only renewal of the configured fqapp installation.

Only a validated replacement Runner.app is installed. Provisioning stubs are
build inputs and are never installed. The persisted expiry is an installation
receipt, not a record of a successful profile build.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

UTC = timezone.utc
MESSAGES = {
    'config_invalid': '续签配置无效，请检查本机设置。',
    'state_invalid': '续签状态记录无效，已停止操作。',
    'source_invalid': '应用源文件校验失败，已停止安装。',
    'profile_invalid': '签名描述文件与应用、设备或证书不匹配。',
    'profile_not_extended': 'Apple 尚未签发更晚到期的描述文件，将于一小时后重试。',
    'entitlements_invalid': '应用签名权限校验失败，已停止安装。',
    'certificate_invalid': '签名证书不在已确认的证书列表中。',
    'device_unavailable': '暂时无法连接 iPhone，请保持连接、信任并解锁设备；一小时后重试。',
    'installed_app_mismatch': '手机上的应用版本与续签来源不同，已停止覆盖。',
    'provisioning_failed': 'Apple 签名准备失败，请检查 Xcode 账号和网络。',
    'signing_failed': '应用重新签名失败，原安装记录已保留。',
    'install_failed': '安装未确认成功，原到期记录已保留。',
    'install_verification_failed': '安装后的应用校验未完成，原到期记录已保留。',
    'cache_restore_failed': '签名缓存恢复失败，请查看本机私有日志。',
    'config_changed': '运行期间续签配置发生变化，已停止操作。',
    'interrupted': '续签被中断，原到期记录已保留。',
    'storage_unavailable': '续签工作目录不可用或空间不足。',
    'native_process_unresolved': '上次续签进程尚未确认结束，已暂停后续签名操作。',
    'internal_error': '续签未完成，请查看本机私有日志。',
}


class RenewalError(Exception):
    def __init__(self, code):
        self.code = code if code in MESSAGES else 'internal_error'
        super().__init__(self.code)


class Deferred(RenewalError):
    pass


class UnsafeProcess(RenewalError):
    pass


class Busy(Exception):
    pass


def utcnow():
    return datetime.now(UTC)


def timestamp(value):
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def parse_time(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        raise ValueError('UTC timestamp required')
    parsed = datetime.fromisoformat(value[:-1] + '+00:00')
    return parsed.astimezone(UTC)


def is_due(expiry, now, window_hours):
    return parse_time(expiry) <= now + timedelta(hours=window_hours)


def require(condition):
    # Validation must remain active even when Python is launched with -O.
    if not condition:
        raise ValueError('validation failed')


def private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise RenewalError('storage_unavailable')
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise RenewalError('storage_unavailable')
    path.chmod(0o700)
    return path


def read_json(path, code, max_bytes=4 * 1024 * 1024):
    path = Path(path)
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > max_bytes:
            raise ValueError('not a bounded regular file')
        value = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(value, dict):
            raise ValueError('object required')
        return value
    except (OSError, ValueError, TypeError):
        raise RenewalError(code) from None


def atomic_json(path, value):
    path = Path(path)
    if path.is_symlink():
        raise RenewalError('storage_unavailable')
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        dir_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


@contextlib.contextmanager
def engine_lock(home):
    path = Path(home) / 'engine.lock'
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy() from None
        yield fd
    finally:
        os.close(fd)


def validate_config(cfg):
    try:
        require(cfg['schema_version'] == 1)
        require(cfg['bundle_id'] == 'com.fqapp.fqapp')
        require(isinstance(cfg['team_id'], str) and re.fullmatch(r'[A-Z0-9]{10}', cfg['team_id']))
        require(re.fullmatch(r'[A-Za-z0-9-]{16,64}', cfg['device_udid']))
        for key in ('version', 'build'):
            require(isinstance(cfg[key], str) and re.fullmatch(r'[0-9A-Za-z._-]{1,40}', cfg[key]))
        for key in ('source_app', 'source_manifest', 'provisioning_project'):
            require(isinstance(cfg[key], str) and Path(cfg[key]).is_absolute())
        require(cfg['source_app'].endswith('.app'))
        require(cfg['provisioning_project'].endswith('.xcodeproj'))
        require(cfg['provisioning_scheme'] == 'ProfilePreparation')
        require(type(cfg['renewal_window_hours']) in (int, float))
        require(1 <= cfg['renewal_window_hours'] <= 168)
        certs = cfg['allowed_certificate_sha1']
        require(isinstance(certs, list) and 1 <= len(certs) <= 8)
        require(all(isinstance(c, str) and re.fullmatch(r'[0-9A-F]{40}', c) for c in certs))
        dirs = cfg['profile_cache_dirs']
        require(isinstance(dirs, list) and 1 <= len(dirs) <= 4)
        require(all(isinstance(p, str) and Path(p).is_absolute() for p in dirs))
        require(len(set(dirs)) == len(dirs))
    except (KeyError, AssertionError, TypeError, ValueError):
        raise RenewalError('config_invalid') from None


def validate_state(state):
    try:
        require(state['schema_version'] == 1 and type(state['paused']) is bool)
        require(state['status'] in {'healthy', 'renewing', 'renewed', 'deferred', 'error', 'paused', 'busy'})
        parse_time(state['installed_expires_at'])
        for key in ('last_check_at', 'last_success_at', 'next_check_at'):
            if state[key] is not None:
                parse_time(state[key])
        for key in ('message', 'error_code', 'notification_id', 'last_run_dir'):
            require(state[key] is None or isinstance(state[key], str))
    except (KeyError, AssertionError, ValueError, TypeError):
        raise RenewalError('state_invalid') from None


def validate_entitlements(actual, cfg):
    exact = {'application-identifier': cfg['team_id'] + '.' + cfg['bundle_id'],
             'com.apple.developer.team-identifier': cfg['team_id'],
             'get-task-allow': True,
             'keychain-access-groups': [cfg['team_id'] + '.' + cfg['bundle_id']]}
    if actual != exact or type(actual.get('get-task-allow')) is not bool:
        raise RenewalError('entitlements_invalid')


def validate_profile(profile, cfg, installed_expiry, now):
    try:
        app_id = cfg['team_id'] + '.' + cfg['bundle_id']
        ent = profile['Entitlements']
        require(profile['TeamIdentifier'] == [cfg['team_id']])
        require(profile['ApplicationIdentifierPrefix'] == [cfg['team_id']])
        require(cfg['device_udid'] in profile['ProvisionedDevices'])
        require(not profile.get('ProvisionsAllDevices', False))
        require(ent['application-identifier'] == app_id)
        require(ent['com.apple.developer.team-identifier'] == cfg['team_id'])
        require(ent['get-task-allow'] is True)
        # Personal-team profiles grant a wildcard; the signed app must narrow it.
        require(ent['keychain-access-groups'] in ([app_id], [cfg['team_id'] + '.*']))
        require(set(ent) == {'application-identifier', 'com.apple.developer.team-identifier',
                            'get-task-allow', 'keychain-access-groups'})
        certificates = profile['DeveloperCertificates']
        require(isinstance(certificates, list) and certificates)
        require(any(hashlib.sha1(c).hexdigest().upper() in cfg['allowed_certificate_sha1']
                   for c in certificates))
        expires = profile['ExpirationDate'].replace(tzinfo=UTC)
        created = profile['CreationDate'].replace(tzinfo=UTC)
        require(created <= now + timedelta(minutes=5))
        require(expires > now and created < expires)
        require(isinstance(profile['UUID'], str) and profile['UUID'])
    except (KeyError, TypeError, ValueError, AttributeError, AssertionError):
        raise RenewalError('profile_invalid') from None
    if expires <= parse_time(installed_expiry) or expires < now + timedelta(days=6):
        raise Deferred('profile_not_extended')
    return timestamp(expires)


def verify_source(app, manifest, cfg):
    app = Path(app)
    try:
        require(not app.is_symlink() and app.is_dir())
        require(all(manifest[k] == cfg[k] for k in ('bundle_id', 'version', 'build')))
        expected = manifest['files']
        require(isinstance(expected, dict) and 1 <= len(expected) <= 10000)
        actual = {}
        for directory, subdirs, files in os.walk(str(app), followlinks=False):
            for name in subdirs + files:
                p = Path(directory) / name
                require(not p.is_symlink())
                require(p.is_dir() or stat.S_ISREG(p.stat().st_mode))
            for name in files:
                p = Path(directory) / name
                rel = p.relative_to(app).as_posix()
                require(p.stat().st_size < 2 * 1024 ** 3)
                digest = hashlib.sha256()
                with p.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
                actual[rel] = {'sha256': digest.hexdigest(), 'mode': stat.S_IMODE(p.stat().st_mode)}
        require(actual == expected)
        require(not any(p.endswith('.appex') for p in (str(p) for p in app.rglob('*'))))
        require(not (app / 'embedded.mobileprovision').exists())
        require(not (app / '_CodeSignature').exists())
        with (app / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        require(info['CFBundleIdentifier'] == cfg['bundle_id'])
        require(info['CFBundleShortVersionString'] == cfg['version'])
        require(str(info['CFBundleVersion']) == cfg['build'])
    except (OSError, KeyError, ValueError, TypeError, AssertionError, plistlib.InvalidFileException):
        raise RenewalError('source_invalid') from None


def matches_profile(profile, cfg):
    return (profile.get('TeamIdentifier') == [cfg['team_id']] and
            isinstance(profile.get('Entitlements'), dict) and
            profile['Entitlements'].get('application-identifier') == cfg['team_id'] + '.' + cfg['bundle_id'])


def restore_profile(original, saved):
    """Retain an independent backup; never replace a new cache entry."""
    if not saved.exists() or os.path.lexists(original):
        return
    fd, temp = tempfile.mkstemp(prefix='.fqapp-restore-', dir=str(original.parent))
    try:
        with os.fdopen(fd, 'wb') as output, saved.open('rb') as source:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        shutil.copystat(saved, temp)
        try:
            os.link(temp, original)  # exclusive creation; no overwriting race
        except FileExistsError:
            pass
    finally:
        os.unlink(temp)


def recover_profile_backups(cfg, runs, decode):
    runs = Path(runs)
    if not runs.exists():
        return
    for journal in sorted(runs.glob('*/profile-backup/restore.json')):
        saved_state = read_json(journal, 'cache_restore_failed')
        if saved_state.get('complete') is True:
            continue
        try:
            for entry in saved_state['files']:
                original, saved = Path(entry['original']), Path(entry['backup'])
                require(str(original.parent) in cfg['profile_cache_dirs'])
                require(original.suffix == '.mobileprovision')
                require(not original.parent.is_symlink() and not saved.is_symlink())
                require(saved.resolve().is_relative_to(journal.parent.resolve()))
                if saved.exists():
                    require(matches_profile(decode(saved), cfg))
                    restore_profile(original, saved)
            saved_state['complete'] = True
            atomic_json(journal, saved_state)
        except (OSError, ValueError, KeyError, TypeError):
            raise RenewalError('cache_restore_failed') from None


@contextlib.contextmanager
def isolate_matching_profiles(cfg, run, decode):
    backup = private_directory(Path(run) / 'profile-backup')
    moved = []
    try:
        for index, value in enumerate(cfg['profile_cache_dirs']):
            cache = Path(value)
            if cache.is_symlink():
                raise RenewalError('config_invalid')
            if not cache.exists():
                continue
            files = sorted(cache.glob('*.mobileprovision'))
            if len(files) > 1000:
                raise RenewalError('config_invalid')
            for path in files:
                if path.is_symlink() or not path.is_file():
                    continue
                try:
                    decoded = decode(path)
                except UnsafeProcess:
                    raise
                except RenewalError:
                    continue  # Unknown and damaged profiles belong to other workflows.
                if not matches_profile(decoded, cfg):
                    continue
                dest = private_directory(backup / str(index)) / path.name
                moved.append((path, dest))
                atomic_json(backup / 'restore.json', {'complete': False, 'files': [
                    {'original': str(a), 'backup': str(b)} for a, b in moved]})
                os.rename(path, dest)
        yield
    finally:
        # Do not touch the cache while a native writer may still be alive.
        if not isinstance(sys.exc_info()[1], UnsafeProcess):
            failed = False
            for original, saved in reversed(moved):
                try:
                    restore_profile(original, saved)
                except OSError:
                    failed = True
            if failed:
                raise RenewalError('cache_restore_failed')
            if moved:
                atomic_json(backup / 'restore.json', {'complete': True, 'files': [
                    {'original': str(a), 'backup': str(b)} for a, b in moved]})


def validate_install_receipt(receipt, cfg):
    try:
        require(receipt['info']['outcome'] == 'success')
        apps = receipt['result']['installedApplications']
        require(len(apps) == 1 and apps[0]['bundleID'] == cfg['bundle_id'])
    except (KeyError, ValueError, TypeError):
        raise RenewalError('install_failed') from None


def validate_installed_apps(receipt, cfg):
    try:
        require(receipt['info']['outcome'] == 'success')
        apps = [a for a in receipt['result']['apps'] if a.get('bundleIdentifier') == cfg['bundle_id']]
        require(len(apps) == 1)
        require(apps[0]['version'] == cfg['version'] and str(apps[0]['bundleVersion']) == cfg['build'])
    except (KeyError, ValueError, TypeError, AttributeError):
        raise RenewalError('installed_app_mismatch') from None


def process_group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def check_unfinished_commands(runs):
    for path in Path(runs).glob('*/*.command.json'):
        record = read_json(path, 'native_process_unresolved')
        if record.get('finished') is True:
            continue
        group = record.get('process_group')
        # Missing identity or a possibly reused group is never killed on recovery.
        if type(group) is not int or group <= 1 or process_group_exists(group):
            raise UnsafeProcess('native_process_unresolved')
        record.update(finished=True, recovered_after_exit=True)
        atomic_json(path, record)


def finish_process_group(process):
    """Quiesce the entire known child group, including leader-exited descendants."""
    if not process_group_exists(process.pid):
        return
    for sig, grace in ((signal.SIGTERM, 3), (signal.SIGKILL, 2)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            process.poll()  # reap the leader without assuming the descendants exited
            if not process_group_exists(process.pid):
                return
            time.sleep(0.05)
    raise UnsafeProcess('native_process_unresolved')


class CommandRunner:
    """Native tool output stays in 0700 run directories and 0600 log files."""
    def __init__(self, run, lock_fd=None):
        self.run_dir = Path(run)
        self.sequence = 0
        self.lock_fd = lock_fd

    def run(self, argv, timeout, code):
        self.sequence += 1
        base = self.run_dir / ('%03d-%s' % (self.sequence, Path(argv[0]).name))
        out_path = base.with_suffix('.stdout.log')
        err_path = base.with_suffix('.stderr.log')
        command_path = base.with_suffix('.command.json')
        command_record = {'argv': [str(a) for a in argv], 'timeout': timeout,
                          'finished': False, 'process_group': None}
        atomic_json(command_path, command_record)
        process = None
        try:
            out_fd = os.open(str(out_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            err_fd = os.open(str(err_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(out_fd, 'wb') as out, os.fdopen(err_fd, 'wb') as err:
                process = subprocess.Popen([str(a) for a in argv], stdin=subprocess.DEVNULL,
                                           stdout=out, stderr=err, start_new_session=True,
                                           pass_fds=() if self.lock_fd is None else (self.lock_fd,))
                command_record['process_group'] = process.pid
                atomic_json(command_path, command_record)
                deadline = time.monotonic() + timeout
                while True:
                    if time.monotonic() >= deadline or out_path.stat().st_size + err_path.stat().st_size > 64 * 1024 * 1024:
                        raise RenewalError(code)
                    try:
                        result = process.wait(timeout=min(1, max(0.01, deadline - time.monotonic())))
                        break
                    except subprocess.TimeoutExpired:
                        continue
            if result != 0 or out_path.stat().st_size > 32 * 1024 * 1024:
                raise RenewalError(code)
            return out_path.read_bytes()
        except OSError:
            raise RenewalError(code) from None
        finally:
            if process is not None:
                finish_process_group(process)
            command_record['finished'] = True
            atomic_json(command_path, command_record)


class NativeBackend:
    def __init__(self, home, config_digest, lock_fd=None):
        self.home = Path(home)
        self.config_digest = config_digest
        self.lock_fd = lock_fd

    def renew(self, cfg, state, run):
        run = Path(run)
        runner = CommandRunner(run, lock_fd=self.lock_fd)
        check_unfinished_commands(self.home / 'runs')
        source = Path(cfg['source_app'])
        manifest = read_json(cfg['source_manifest'], 'source_invalid')
        verify_source(source, manifest, cfg)
        if shutil.disk_usage(run).free < 1024 ** 3:
            raise RenewalError('storage_unavailable')

        def query_apps(path, before=False):
            try:
                runner.run(['/usr/bin/xcrun', 'devicectl', 'device', 'info', 'apps',
                            '--device', cfg['device_udid'], '--bundle-id', cfg['bundle_id'],
                            '--json-output', str(path), '--timeout', '30'], 45,
                           'device_unavailable' if before else 'install_verification_failed')
                result = read_json(path, 'device_unavailable' if before else 'install_verification_failed')
            except RenewalError as error:
                if before and error.code == 'device_unavailable':
                    raise Deferred('device_unavailable') from None
                raise
            try:
                validate_installed_apps(result, cfg)
            except RenewalError:
                if before:
                    raise
                raise RenewalError('install_verification_failed') from None

        # Device access and exact installed version are checked before cache changes.
        query_apps(run / 'device-before.json', before=True)
        app = run / 'Runner.app'
        shutil.copytree(source, app, copy_function=shutil.copy2)
        verify_source(app, manifest, cfg)
        app_binary = app / 'Frameworks/App.framework/App'
        if not app_binary.is_file() or app_binary.is_symlink():
            raise RenewalError('source_invalid')
        app_binary.chmod(0o755)

        def decode(path):
            data = runner.run(['/usr/bin/security', 'cms', '-D', '-i', str(path)], 15, 'profile_invalid')
            try:
                result = plistlib.loads(data)
                if not isinstance(result, dict):
                    raise ValueError()
                return result
            except (ValueError, plistlib.InvalidFileException):
                raise RenewalError('profile_invalid') from None

        derived = run / 'DerivedData'
        recover_profile_backups(cfg, self.home / 'runs', decode)
        with isolate_matching_profiles(cfg, run, decode):
            runner.run(['/usr/bin/xcodebuild', '-project', cfg['provisioning_project'],
                        '-scheme', cfg['provisioning_scheme'], '-configuration', 'Debug',
                        '-sdk', 'iphoneos', '-destination', 'platform=iOS,id=' + cfg['device_udid'],
                        '-derivedDataPath', str(derived), '-allowProvisioningUpdates',
                        '-allowProvisioningDeviceRegistration', 'build'], 600, 'provisioning_failed')
            stub = derived / 'Build/Products/Debug-iphoneos/ProfilePreparation.app'
            runner.run(['/usr/bin/codesign', '--verify', '--strict', str(stub)], 30, 'signing_failed')
            embedded = stub / 'embedded.mobileprovision'
            new_profile = decode(embedded)
            expires = validate_profile(new_profile, cfg, state['installed_expires_at'], utcnow())
            try:
                ent = plistlib.loads(runner.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(stub)],
                                               20, 'entitlements_invalid'))
            except (ValueError, plistlib.InvalidFileException):
                raise RenewalError('entitlements_invalid') from None
            validate_entitlements(ent, cfg)
            cert_prefix = str(run / 'signer-')
            runner.run(['/usr/bin/codesign', '--display', '--extract-certificates=' + cert_prefix, str(stub)],
                       20, 'certificate_invalid')
            cert_path = Path(cert_prefix + '0')
            if not cert_path.is_file() or cert_path.is_symlink():
                raise RenewalError('certificate_invalid')
            certificate = cert_path.read_bytes()
            cert_sha1 = hashlib.sha1(certificate).hexdigest().upper()
            if cert_sha1 not in cfg['allowed_certificate_sha1'] or certificate not in new_profile['DeveloperCertificates']:
                raise RenewalError('certificate_invalid')
            ent_path = run / 'signing-entitlements.plist'
            ent_path.write_bytes(plistlib.dumps(ent))
            ent_path.chmod(0o600)
            shutil.copy2(embedded, app / 'embedded.mobileprovision')
            frameworks = sorted((app / 'Frameworks').glob('*.framework'))
            if len(frameworks) != 13:
                raise RenewalError('source_invalid')
            for framework in frameworks:
                runner.run(['/usr/bin/codesign', '--force', '--sign', cert_sha1,
                            '--timestamp=none', str(framework)], 60, 'signing_failed')
            runner.run(['/usr/bin/codesign', '--force', '--sign', cert_sha1,
                        '--entitlements', str(ent_path), '--generate-entitlement-der',
                        '--timestamp=none', str(app)], 90, 'signing_failed')
            runner.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], 60, 'signing_failed')
            try:
                signed_ent = plistlib.loads(runner.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                                                       20, 'entitlements_invalid'))
            except (ValueError, plistlib.InvalidFileException):
                raise RenewalError('entitlements_invalid') from None
            validate_entitlements(signed_ent, cfg)
        # All profile-cache restoration finishes before any installation.
        verify_source(source, manifest, cfg)
        if hashlib.sha256((self.home / 'config.json').read_bytes()).hexdigest() != self.config_digest:
            raise RenewalError('config_changed')
        query_apps(run / 'device-preinstall.json', before=True)
        receipt = run / 'device-install.json'
        runner.run(['/usr/bin/xcrun', 'devicectl', 'device', 'install', 'app',
                    '--device', cfg['device_udid'], str(app), '--json-output', str(receipt),
                    '--timeout', '120'], 140, 'install_failed')
        validate_install_receipt(read_json(receipt, 'install_failed'), cfg)
        query_apps(run / 'installed-app-info.json')
        atomic_json(run / 'verified-renewal.json', {'installed_expires_at': expires,
                    'profile_uuid': new_profile['UUID'], 'certificate_sha1': cert_sha1,
                    'bundle_id': cfg['bundle_id'], 'version': cfg['version'], 'build': cfg['build']})
        return expires


def event_id(kind, *values):
    return kind + '-' + hashlib.sha256('|'.join(str(v) for v in values).encode()).hexdigest()[:20]


def execute(home, command, now=None, backend=None):
    """Return (sanitized state, exit code); status is strictly read-only."""
    home = Path(home).absolute()
    now = now or utcnow()
    state = None
    try:
        state = read_json(home / 'state.json', 'state_invalid')
        validate_state(state)
        if command == 'status':
            return state, 1 if state['status'] == 'error' else 0
        private_directory(home)
        with engine_lock(home) as lock_fd:
            # Re-read after lock acquisition to avoid overwriting a concurrent result.
            state = read_json(home / 'state.json', 'state_invalid')
            validate_state(state)
            config_path = home / 'config.json'
            if config_path.is_symlink() or config_path.stat().st_size > 64 * 1024:
                raise RenewalError('config_invalid')
            config_bytes = config_path.read_bytes()
            try:
                cfg = json.loads(config_bytes)
            except (ValueError, UnicodeError):
                raise RenewalError('config_invalid') from None
            validate_config(cfg)
            config_digest = hashlib.sha256(config_bytes).hexdigest()
            if command in ('pause', 'resume'):
                state.update(paused=command == 'pause', status='paused' if command == 'pause' else 'healthy',
                             message='自动续签已暂停。' if command == 'pause' else '自动续签已恢复。',
                             next_check_at=None if command == 'pause' else timestamp(now),
                             error_code=None, notification_id=None)
                atomic_json(home / 'state.json', state)
                return state, 0
            if command == 'check' and state['paused']:
                state.update(status='paused', message='自动续签已暂停。', next_check_at=None)
                atomic_json(home / 'state.json', state)
                return state, 0
            if command == 'check' and state['status'] in ('deferred', 'error') and state['next_check_at']:
                if parse_time(state['next_check_at']) > now:
                    return state, 1 if state['status'] == 'error' else 0
            state['last_check_at'] = timestamp(now)
            if command == 'check' and not is_due(state['installed_expires_at'], now, cfg['renewal_window_hours']):
                state.update(status='healthy', message='签名有效，进入续签窗口后自动处理。',
                             next_check_at=timestamp(now + timedelta(hours=1)), error_code=None)
                atomic_json(home / 'state.json', state)
                return state, 0
            runs = private_directory(home / 'runs')
            run = Path(tempfile.mkdtemp(prefix=now.strftime('%Y%m%dT%H%M%SZ-'), dir=str(runs)))
            state.update(status='renewing', message='正在准备签名并续装 fqapp。', error_code=None,
                         last_run_dir=str(run), next_check_at=None)
            atomic_json(home / 'state.json', state)
            try:
                expires = (backend or NativeBackend(home, config_digest, lock_fd)).renew(cfg, dict(state), run)
                if parse_time(expires) <= parse_time(state['installed_expires_at']):
                    raise RenewalError('profile_not_extended')
                state.update(installed_expires_at=expires, last_success_at=timestamp(now),
                             status='renewed', message='fqapp 续签及安装已验证成功。', error_code=None,
                             notification_id=event_id('renewed', expires),
                             next_check_at=timestamp(now + timedelta(hours=1)))
                exit_code = 0
            except (RenewalError, KeyboardInterrupt, InterruptedError) as error:
                if not isinstance(error, RenewalError):
                    error = RenewalError('interrupted')
                deferred = isinstance(error, Deferred)
                notify = not deferred or is_due(state['installed_expires_at'], now, 24)
                state.update(status='deferred' if deferred else 'error', message=MESSAGES[error.code],
                             error_code=error.code, next_check_at=timestamp(now + timedelta(hours=1)),
                             notification_id=event_id('deferred' if deferred else 'error', error.code,
                                                      state['installed_expires_at']) if notify else None)
                exit_code = 0 if deferred else 1
            except Exception:
                state.update(status='error', message=MESSAGES['internal_error'], error_code='internal_error',
                             notification_id=event_id('error', 'internal_error', state['installed_expires_at']),
                             next_check_at=timestamp(now + timedelta(hours=1)))
                exit_code = 1
            atomic_json(home / 'state.json', state)
            return state, exit_code
    except Busy:
        return dict(state, status='busy', message='已有续签任务正在运行。'), 0
    except (RenewalError, OSError, ValueError, TypeError) as error:
        code = error.code if isinstance(error, RenewalError) else 'storage_unavailable'
        # Invalid input files are never replaced with guessed state.
        output = dict(state) if isinstance(state, dict) else {'schema_version': 1}
        output.update(status='error', message=MESSAGES[code], error_code=code,
                      notification_id=event_id('error', code))
        return output, 1


def main(argv=None):
    parser = argparse.ArgumentParser(description='fqapp 本机自动续签')
    parser.add_argument('--home', required=True)
    parser.add_argument('command', choices=['check', 'renew', 'status', 'pause', 'resume'])
    args = parser.parse_args(argv)
    os.umask(0o077)
    def interrupted(signum, frame):
        raise InterruptedError('termination requested')
    signal.signal(signal.SIGTERM, interrupted)
    result, code = execute(args.home, args.command)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return code


if __name__ == '__main__':
    sys.exit(main())
