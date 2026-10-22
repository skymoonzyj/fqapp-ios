#!/usr/bin/env python3
"""Collect minimal, source-bound iOS check evidence and reject incomplete runs.

Only these JSON summaries are suitable for CI upload. Command output stays on
stdout; raw logs, xcresults, runtime directories and media are never copied.
Physical G1/G4/G5 acceptance remains separate from this automated gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

REQUIRED_CHECKS = (
    'flutter_analyze', 'diff_check', 'rustfmt', 'clippy', 'flutter_tests',
    'rust_tests', 'frb_host_tests', 'c_tests', 'verifier_tests',
    'build_script_tests', 'media_encoders', 'ios_simulator_build',
    'runner_tests', 'ios_acceptance', 'media_fixtures', 'ios_native_media',
)
MACHINE_CHECKS = ('flutter_tests', 'frb_host_tests')
DRIVE_CHECKS = {
    'ios_native_media': {
        'iOS static core initializes, requests, cancels, shuts down and restarts',
        'local iOS plugins, AVPlayer first frame and Rust lease release',
    },
    'ios_acceptance': {
        'cold bootstrap reaches the packaged Rust core health endpoint',
        'search to detail to reading persists progress and reopens offline',
        'media controls preserve play pause and seek state with injected adapter',
    },
}
COUNTED_CHECKS = ('rust_tests', 'c_tests', 'runner_tests', 'build_script_tests', 'verifier_tests')
IDENTITY_FIELDS = ('schema_version', 'run_id', 'source_sha', 'dirty_diff_sha256')


HARDWARE_ONLY_TEST = 'DiagnosticsTests.testFileProtectionAttributeOnPhysicalDevice'
HARDWARE_SKIP_REASON = 'Simulator does not expose Data Protection attributes; physical-device verification pending'


def is_simulator_xctest(command):
    if (not isinstance(command, list) or not command or
            any(not isinstance(argument, str) for argument in command) or
            Path(command[0]).name != 'xcodebuild'):
        return False
    # The exception belongs to our one explicit Simulator run. An additional
    # destination, including the = spelling or a missing value, is ambiguous.
    destinations = [index for index, argument in enumerate(command)
                    if argument == '-destination' or argument.startswith('-destination=')]
    if len(destinations) != 1:
        return False
    index = destinations[0]
    if command[index] != '-destination' or index + 1 >= len(command):
        return False
    fields = [field.split('=', 1) for field in command[index + 1].split(',')]
    if any(len(field) != 2 or not all(field) for field in fields):
        return False
    values = dict(fields)
    return len(values) == len(fields) and values.get('platform') == 'iOS Simulator'


def allowed_runner_skip(report):
    return (is_simulator_xctest(report.get('command')) and
            report.get('skipped_tests') == [HARDWARE_ONLY_TEST] and
            report.get('noncritical_skips') == [{
                'test_id': HARDWARE_ONLY_TEST, 'platform': 'iOS Simulator',
                'reason': HARDWARE_SKIP_REASON, 'physical_gate': 'G5:not_run'}])


def read_object(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('expected JSON object')
    return value


def verify_reports(reports_dir, source_sha, dirty_diff_sha256):
    reports_dir = Path(reports_dir)
    errors = []
    checked = {}
    try:
        manifest = read_object(reports_dir / 'manifest.json')
    except (OSError, ValueError) as error:
        manifest = {}
        errors.append(f'manifest: invalid or missing ({type(error).__name__})')
    if manifest.get('schema_version') != 1:
        errors.append('manifest: unsupported schema_version')
    if not manifest.get('run_id'):
        errors.append('manifest: missing run_id')
    if manifest.get('source_sha') != source_sha:
        errors.append('manifest: source_sha does not match current checkout')
    if manifest.get('dirty_diff_sha256') != dirty_diff_sha256:
        errors.append('manifest: dirty_diff_sha256 does not match current checkout')
    if not isinstance(manifest.get('tools'), dict) or not manifest.get('tools'):
        errors.append('manifest: missing tool versions')
    for name in REQUIRED_CHECKS:
        path = reports_dir / f'{name}.json'
        if not path.exists():
            errors.append(f'{name}: missing report')
            checked[name] = 'not_run'
            continue
        try:
            report = read_object(path)
        except (OSError, ValueError) as error:
            errors.append(f'{name}: invalid report ({type(error).__name__})')
            checked[name] = 'failed'
            continue
        checked[name] = report.get('status', 'not_run')
        for field in IDENTITY_FIELDS:
            if report.get(field) != manifest.get(field):
                errors.append(f'{name}: mismatched {field}')
        if report.get('check') != name:
            errors.append(f'{name}: wrong check identity')
        if report.get('status') != 'passed':
            errors.append(f'{name}: {report.get("status", "not_run")}')
        if type(report.get('exit_code')) is not int or report['exit_code'] != 0:
            errors.append(f'{name}: exit_code is not zero')
        if not isinstance(report.get('tools'), dict) or not report.get('tools'):
            errors.append(f'{name}: missing tool versions')
        if report.get('tools') != manifest.get('tools'):
            errors.append(f'{name}: tool versions differ from run manifest')
        if not isinstance(report.get('command'), list) or not report.get('command'):
            errors.append(f'{name}: missing command')
        if not isinstance(report.get('reason'), str):
            errors.append(f'{name}: missing reason')
        for field in ('critical_skips', 'skipped_tests'):
            if not isinstance(report.get(field), list):
                errors.append(f'{name}: missing {field}')
        if name in MACHINE_CHECKS and (report.get('machine_completed') is not True or
                                       type(report.get('tests_passed')) is not int or
                                       report['tests_passed'] < 1):
            errors.append(f'{name}: missing successful machine test evidence')
        if name != 'flutter_tests' and report.get('skipped_tests') and not (name == 'runner_tests' and allowed_runner_skip(report)):
            errors.append(f'{name}: skipped tests are not allowed')
        if name in DRIVE_CHECKS and (report.get('integration_completed') is not True or
                                    report.get('tests_passed') != len(DRIVE_CHECKS[name])):
            errors.append(f'{name}: missing complete actual integration result inventory')
        if name in COUNTED_CHECKS and (type(report.get('tests_passed')) is not int or
                                       report['tests_passed'] < 1):
            errors.append(f'{name}: missing nonzero test evidence')
        if report.get('critical_skips'):
            errors.append(f'{name}: critical tests skipped')
    return {
        'schema_version': 1, 'source_sha': source_sha,
        'dirty_diff_sha256': dirty_diff_sha256, 'passed': not errors,
        'release_ready': False, 'checks': checked, 'errors': errors,
        'physical_acceptance': {'G1': 'not_run', 'G4': 'not_run', 'G5': 'not_run'},
        'physical_acceptance_reason': 'Separate device acceptance evidence required; automated checks do not close G1/G4/G5.',
    }


def git_bytes(root, *args):
    return subprocess.check_output(['git', *args], cwd=root)


def source_identity(root):
    """Include staged/unstaged changes and nonignored untracked source bytes."""
    sha = git_bytes(root, 'rev-parse', 'HEAD').decode().strip()
    digest = hashlib.sha256(git_bytes(root, 'diff', '--binary', 'HEAD', '--'))
    untracked = git_bytes(root, 'ls-files', '-z', '--others', '--exclude-standard')
    for entry in sorted(filter(None, untracked.split(b'\0'))):
        path = root / os.fsdecode(entry)
        digest.update(entry + b'\0')
        digest.update(path.read_bytes() if path.is_file() else b'<non-file>')
    return sha, digest.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def initialize(root, directory, tools_file):
    sha, dirty = source_identity(root)
    tools = read_object(tools_file)
    if not tools or any(not isinstance(value, str) or not value for value in tools.values()):
        raise ValueError('tool versions must be a nonempty object of nonempty strings')
    if (directory / 'manifest.json').exists():
        raise ValueError('reports directory already initialized; use a fresh directory for every run')
    write_json(directory / 'manifest.json', {
        'schema_version': 1, 'run_id': str(uuid.uuid4()),
        'source_sha': sha, 'dirty_diff_sha256': dirty, 'tools': tools,
    })


# Only explicitly noncritical tests may be skipped in the full Flutter pass.
# Host tests must pass, without skips, again through frb_host_tests.
NONCRITICAL_FLUTTER_SKIPS = (
    'Windows SDK semantics backport',
    'pagination previews show full lines and the mode selector',
)


def run_check(root, directory, name, command):
    if name not in REQUIRED_CHECKS or not command:
        raise ValueError('known required check and a command after -- are required')
    manifest = read_object(directory / 'manifest.json')
    report = {**manifest, 'check': name, 'command': command, 'status': 'failed',
              'exit_code': None, 'reason': '', 'critical_skips': [], 'skipped_tests': [],
              'tests_passed': 0, 'machine_completed': False, 'integration_completed': False,
              'noncritical_skips': []}
    expected = (manifest['source_sha'], manifest['dirty_diff_sha256'])
    if source_identity(root) != expected:
        report['reason'] = 'source changed before command'
        write_json(directory / f'{name}.json', report)
        return 1
    tests = {}
    suites = {}
    unittest_skips_individual = 0
    unittest_skips_summary = 0
    runner_skips = set()
    runner_skip_total = 0
    runner_hardware_reason = False
    try:
        process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, errors='replace')
        for line in process.stdout:
            print(line, end='', flush=True)
            if name == 'runner_tests':
                runner_hardware_reason = runner_hardware_reason or HARDWARE_SKIP_REASON in line
                case = re.search(r"Test Case '-\[(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' skipped", line)
                if case:
                    runner_skips.add(f'{case[1]}.{case[2]}')
                total = re.search(r'(\d+) tests? skipped', line)
                if total:
                    runner_skip_total = max(runner_skip_total, int(total[1]))
            if name == 'verifier_tests':
                # unittest's Ran N counts skipped cases too. Capture both
                # verbosity=2 lines and the final summary without double-counting.
                if re.search(r'\.\.\. skipped(?:\s|$)', line):
                    unittest_skips_individual += 1
                summary = re.search(r'\bskipped=(\d+)\b', line)
                if summary:
                    unittest_skips_summary += int(summary[1])
            if name in COUNTED_CHECKS:
                patterns = {
                    'rust_tests': r'test result: ok\. (\d+) passed;',
                    'c_tests': r'(?:#|ℹ) pass (\d+)',
                    'build_script_tests': r'(?:#|ℹ) pass (\d+)',
                    'runner_tests': r'Executed (\d+) tests?',
                    'verifier_tests': r'Ran (\d+) tests? in',
                }
                match = re.search(patterns[name], line)
                if match:
                    report['tests_passed'] = (max(report['tests_passed'], int(match[1])) if name == 'runner_tests'
                                              else report['tests_passed'] + int(match[1]))
                for pattern in (r'(\d+) ignored;', r'(?:#|ℹ) skipped (\d+)',
                                r'(\d+) tests? skipped'):
                    skipped = re.search(pattern, line)
                    if name != 'runner_tests' and skipped and int(skipped[1]):
                        label = f'{skipped[1]} test(s) skipped/ignored in {name}'
                        report['skipped_tests'].append(label)
                        report['critical_skips'].append(label)
            # Flutter --machine emits NDJSON. Record only names of skipped
            # tests, never payloads/URLs/errors that may contain private data.
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            if name in DRIVE_CHECKS and event.get('type') == 'fqapp.integration.result':
                required = DRIVE_CHECKS[name]
                declared, results = event.get('expected_tests'), event.get('results')
                report['integration_completed'] = (
                    event.get('schema_version') == 1 and event.get('entry') == name and
                    isinstance(declared, list) and len(declared) == len(required) and
                    all(isinstance(test, str) for test in declared) and set(declared) == required and isinstance(results, dict) and
                    set(results) == required and all(value == 'success' for value in results.values()))
                report['tests_passed'] = sum(results.get(test) == 'success' for test in required) if isinstance(results, dict) else 0
                if isinstance(results, dict):
                    absent = sorted(required - set(results))
                    report['skipped_tests'].extend(absent)
                    report['critical_skips'].extend(absent)
            if event.get('type') == 'suite':
                suite = event.get('suite', {})
                suites[suite.get('id')] = suite
            if event.get('type') == 'done':
                report['machine_completed'] = event.get('success') is True
            if event.get('type') == 'testDone' and not event.get('skipped') and event.get('result') == 'success':
                report['tests_passed'] += 1
            if event.get('type') == 'testStart':
                test = event.get('test', {})
                tests[test.get('id')] = test
            if event.get('type') == 'testDone' and event.get('skipped'):
                test = tests.get(event.get('testID'), {})
                label = test.get('name', 'unnamed skipped test')
                report['skipped_tests'].append(label)
                host_deferred = (name == 'flutter_tests' and
                                 str(test.get('url') or suites.get(test.get('suiteID'), {}).get('path', '')).endswith('/rust_host_integration_test.dart'))
                optional = name == 'flutter_tests' and label in NONCRITICAL_FLUTTER_SKIPS
                if not (host_deferred or optional):
                    report['critical_skips'].append(label)
        process.stdout.close()
        report['exit_code'] = process.wait()
        if name == 'runner_tests':
            skipped = max(runner_skip_total, len(runner_skips))
            report['tests_passed'] = max(0, report['tests_passed'] - skipped)
            report['tests_skipped_count'] = skipped
            if skipped:
                report['skipped_tests'] = sorted(runner_skips) or [f'{skipped} unclassified XCTest skip(s)']
                if skipped == 1 and runner_skips == {HARDWARE_ONLY_TEST} and runner_hardware_reason and is_simulator_xctest(command):
                    report['noncritical_skips'] = [{'test_id': HARDWARE_ONLY_TEST, 'platform': 'iOS Simulator',
                        'reason': HARDWARE_SKIP_REASON, 'physical_gate': 'G5:not_run'}]
                else:
                    report['critical_skips'] = report['skipped_tests'].copy()
        if name == 'verifier_tests':
            skipped = max(unittest_skips_individual, unittest_skips_summary)
            report['tests_passed'] = max(0, report['tests_passed'] - skipped)
            report['tests_skipped_count'] = skipped
            if skipped:
                label = f'{skipped} unittest case(s) skipped'
                report['skipped_tests'].append(label)
                report['critical_skips'].append(label)
        if source_identity(root) != expected:
            report['reason'] = 'source changed while command was running'
        elif report['critical_skips']:
            report['reason'] = 'critical tests skipped'
        elif name in MACHINE_CHECKS and (not report['machine_completed'] or report['tests_passed'] < 1):
            report['reason'] = 'missing successful machine test evidence'
        elif name in DRIVE_CHECKS and not report['integration_completed']:
            report['reason'] = 'missing complete actual integration result inventory'
        elif name in COUNTED_CHECKS and report['tests_passed'] < 1:
            report['reason'] = 'missing nonzero test evidence'
        elif report['exit_code'] != 0:
            report['reason'] = 'command failed; inspect local/CI console output'
        else:
            report['status'] = 'passed'
    except OSError as error:
        report['reason'] = f'command unavailable ({type(error).__name__})'
    write_json(directory / f'{name}.json', report)
    return 0 if report['status'] == 'passed' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--init', dest='tools_file', type=Path,
                        help='initialize a fresh run from a minimal tool-versions JSON')
    parser.add_argument('--run-check', choices=REQUIRED_CHECKS)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        if args.tools_file:
            initialize(root, args.reports_dir, args.tools_file)
            return 0
        if args.run_check:
            command = args.command[1:] if args.command[:1] == ['--'] else args.command
            return run_check(root, args.reports_dir, args.run_check, command)
        if not args.output:
            parser.error('--output is required when aggregating reports')
        sha, dirty = source_identity(root)
        result = verify_reports(args.reports_dir, sha, dirty)
        write_json(args.output, result)
        print('automated checks: ' + ('passed' if result['passed'] else 'FAILED'))
        for error in result['errors']:
            print(error, file=sys.stderr)
        return 0 if result['passed'] else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'iOS check evidence error: {type(error).__name__}: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
