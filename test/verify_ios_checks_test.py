"""Release gate contract: stale or incomplete evidence never becomes green."""
import contextlib
import io
import sys
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'verify_ios_checks.py'
spec = importlib.util.spec_from_file_location('verify_ios_checks', SCRIPT)
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

SHA = 'a' * 40
DIRTY = 'b' * 64


class VerifyIosChecksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = {
            'schema_version': 1, 'run_id': 'fixture-run',
            'source_sha': SHA, 'dirty_diff_sha256': DIRTY,
            'tools': {'flutter': '3.44.6', 'dart': '3.12.2', 'rustc': '1.99.1'},
        }
        self.write('manifest.json', self.manifest)
        for name in checks.REQUIRED_CHECKS:
            self.write(name + '.json', self.report(name))

    def report(self, name):
        return {
            **self.manifest, 'check': name, 'status': 'passed',
            'exit_code': 0, 'reason': '', 'critical_skips': [],
            'skipped_tests': [], 'command': ['fixture-command'],
            'tests_passed': len(checks.DRIVE_CHECKS.get(name, [1])),
            'machine_completed': True, 'integration_completed': True,
        }

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def verify(self):
        return checks.verify_reports(self.root, SHA, DIRTY)

    def test_complete_same_source_passes_with_physical_gates_pending(self):
        result = self.verify()
        self.assertTrue(result['passed'])
        self.assertFalse(result['release_ready'])
        self.assertEqual(result['physical_acceptance']['G1'], 'not_run')
        self.assertEqual(result['physical_acceptance']['G4'], 'not_run')

    def test_missing_required_report_fails(self):
        (self.root / 'frb_host_tests.json').unlink()
        self.assertIn('frb_host_tests: missing report', self.verify()['errors'])

    def test_failed_skipped_and_not_run_are_blockers(self):
        for status in ('failed', 'skipped', 'not_run'):
            with self.subTest(status=status):
                report = self.report('runner_tests')
                report.update(status=status, reason='fixture unavailable')
                self.write('runner_tests.json', report)
                self.assertFalse(self.verify()['passed'])

    def test_mismatched_sha_fails_even_if_all_reports_agree(self):
        self.assertFalse(checks.verify_reports(self.root, 'c' * 40, DIRTY)['passed'])

    def test_single_old_report_fails(self):
        report = self.report('rust_tests')
        report['source_sha'] = 'd' * 40
        self.write('rust_tests.json', report)
        self.assertFalse(self.verify()['passed'])

    def test_dirty_source_and_run_identity_must_match(self):
        for field, value in [('dirty_diff_sha256', 'c' * 64), ('run_id', 'old-run')]:
            with self.subTest(field=field):
                report = self.report('c_tests')
                report[field] = value
                self.write('c_tests.json', report)
                self.assertFalse(self.verify()['passed'])

    def test_nonzero_exit_cannot_claim_passed(self):
        report = self.report('flutter_tests')
        report['exit_code'] = 1
        self.write('flutter_tests.json', report)
        self.assertFalse(self.verify()['passed'])

    def test_critical_skip_cannot_claim_passed(self):
        report = self.report('frb_host_tests')
        report['critical_skips'] = ['Rust host library unavailable']
        self.write('frb_host_tests.json', report)
        self.assertFalse(self.verify()['passed'])

    def test_missing_required_metadata_fails(self):
        for field in ('tools', 'command', 'reason', 'critical_skips', 'skipped_tests'):
            with self.subTest(field=field):
                report = self.report('flutter_analyze')
                del report[field]
                self.write('flutter_analyze.json', report)
                self.assertFalse(self.verify()['passed'])

    def test_malformed_json_is_a_reported_failure(self):
        (self.root / 'rustfmt.json').write_text('{')
        self.assertFalse(self.verify()['passed'])

    def test_invalid_manifest_is_a_reported_failure(self):
        self.write('manifest.json', [])
        self.assertFalse(self.verify()['passed'])

    def test_extra_reports_cannot_replace_required_checks(self):
        (self.root / 'runner_tests.json').unlink()
        self.write('G1.json', self.report('G1'))
        self.assertFalse(self.verify()['passed'])

    def test_disguised_report_name_fails(self):
        self.write('runner_tests.json', self.report('flutter_tests'))
        self.assertFalse(self.verify()['passed'])


    def test_unclassified_skip_cannot_claim_passed(self):
        report = self.report('ios_acceptance')
        report['skipped_tests'] = ['cold launch']
        self.write('ios_acceptance.json', report)
        self.assertFalse(self.verify()['passed'])

    def test_tool_versions_must_match_the_run_manifest(self):
        report = self.report('flutter_tests')
        report['tools'] = {'flutter': 'older'}
        self.write('flutter_tests.json', report)
        self.assertFalse(self.verify()['passed'])

    def run_xctest_fixture(self, simulator=True, known=True, reason=True, destination_args=None):
        identifier = 'testFileProtectionAttributeOnPhysicalDevice' if known else 'testUnexpectedCriticalContract'
        lines = []
        if reason:
            lines.append('Test skipped - Simulator does not expose Data Protection attributes; physical-device verification pending')
        lines.extend([f"Test Case '-[RunnerTests.DiagnosticsTests {identifier}]' skipped (0.001 seconds).",
                      'Executed 9 tests, with 1 test skipped and 0 failures',
                      'Executed 9 tests, with 1 test skipped and 0 failures'])
        tool = self.root / 'xcodebuild'
        tool.write_text('#!' + sys.executable + '\nprint(' + repr('\n'.join(lines)) + ')\n')
        tool.chmod(0o755)
        destination = 'platform=iOS Simulator,id=fixture' if simulator else 'platform=iOS,id=fixture'
        with patch.object(checks, 'source_identity', return_value=(SHA, DIRTY)):
            with contextlib.redirect_stdout(io.StringIO()):
                code = checks.run_check(self.root, self.root, 'runner_tests',
                                        [str(tool), *(destination_args if destination_args is not None else ['-destination', destination]), 'test'])
        return code, json.loads((self.root / 'runner_tests.json').read_text())

    def test_simulator_hardware_only_exact_skip_is_retained_without_counting_pass(self):
        code, report = self.run_xctest_fixture()
        self.assertEqual(code, 0)
        self.assertEqual(report['tests_passed'], 8)
        self.assertEqual(report['skipped_tests'], ['DiagnosticsTests.testFileProtectionAttributeOnPhysicalDevice'])
        self.assertEqual(report['noncritical_skips'][0]['physical_gate'], 'G5:not_run')
        self.assertFalse(report['critical_skips'])
        self.assertTrue(self.verify()['passed'])

    def test_physical_device_never_allows_the_simulator_hardware_skip(self):
        code, _ = self.run_xctest_fixture(simulator=False)
        self.assertEqual(code, 1)

    def test_hardware_skip_rejects_mixed_multiple_and_unknown_destinations(self):
        simulator = 'platform=iOS Simulator,id=fixture'
        for arguments in (
            ['-destination', simulator, '-destination', 'platform=iOS,id=physical'],
            ['-destination', simulator, '-destination', simulator],
            ['-destination', simulator, '-destination=platform=iOS,id=physical'],
            ['-destination', simulator, '-destination'],
            ['-destination', 'id=unknown'],
            ['-destination', 'platform=iOS Simulator,platform=iOS'],
            ['-destination', 'platform=iOS Simulator,id='],
            ['-destination=platform=iOS Simulator,id=fixture'],
            [],
        ):
            with self.subTest(arguments=arguments):
                code, report = self.run_xctest_fixture(destination_args=arguments)
                self.assertEqual(code, 1)
                self.assertTrue(report['critical_skips'])
                self.assertFalse(self.verify()['passed'])

    def test_aggregate_rejects_reclassified_mixed_destination_skip(self):
        code, report = self.run_xctest_fixture()
        self.assertEqual(code, 0)
        report['command'].extend(['-destination', 'platform=iOS,id=physical'])
        self.write('runner_tests.json', report)
        self.assertFalse(self.verify()['passed'])

    def test_other_or_unexplained_xctest_skip_stays_critical(self):
        for arguments in ({'known': False}, {'reason': False}):
            with self.subTest(arguments=arguments):
                code, _ = self.run_xctest_fixture(**arguments)
                self.assertEqual(code, 1)

    def run_drive_result(self, payload):
        event = {'type': 'fqapp.integration.result', 'schema_version': 1,
                 'entry': 'ios_native_media', **payload}
        return self.run_machine('ios_native_media', [event])

    def test_actual_drive_inventory_passes_without_fabricated_machine_events(self):
        names = [
            'iOS static core initializes, requests, cancels, shuts down and restarts',
            'local iOS plugins, AVPlayer first frame and Rust lease release',
        ]
        code = self.run_drive_result({'expected_tests': names,
                                     'results': {name: 'success' for name in names}})
        self.assertEqual(code, 0)
        report = json.loads((self.root / 'ios_native_media.json').read_text())
        self.assertEqual(report['tests_passed'], 2)
        self.assertTrue(report['integration_completed'])
        self.assertFalse(report['machine_completed'])

    def test_drive_zero_or_missing_or_skipped_results_never_pass(self):
        for results in ({}, {'local iOS plugins, AVPlayer first frame and Rust lease release': 'success'}):
            with self.subTest(results=results):
                self.assertEqual(self.run_drive_result({'expected_tests': list(results), 'results': results}), 1)

    def test_drive_failure_result_never_passes(self):
        names = [
            'iOS static core initializes, requests, cancels, shuts down and restarts',
            'local iOS plugins, AVPlayer first frame and Rust lease release',
        ]
        self.assertEqual(self.run_drive_result({'expected_tests': names,
                         'results': {names[0]: 'success', names[1]: 'failed'}}), 1)

    def run_unittest_skip(self, all_skipped=False):
        script = """import unittest
class Contract(unittest.TestCase):
    @unittest.skip('fixture unavailable')
    def test_skipped(self): pass
"""
        if not all_skipped:
            script += "    def test_passed(self): self.assertTrue(True)\n"
        script += "unittest.main(argv=['fixture'], verbosity=2)\n"
        with patch.object(checks, 'source_identity', return_value=(SHA, DIRTY)):
            with contextlib.redirect_stdout(io.StringIO()):
                code = checks.run_check(self.root, self.root, 'verifier_tests',
                                        [sys.executable, '-c', script])
        return code, json.loads((self.root / 'verifier_tests.json').read_text())

    def test_actual_unittest_mixed_pass_skip_blocks_and_counts_only_passed(self):
        code, report = self.run_unittest_skip()
        self.assertEqual(code, 1)
        self.assertEqual(report['tests_passed'], 1)
        self.assertTrue(report['critical_skips'])

    def test_actual_unittest_all_skipped_blocks_with_zero_passed(self):
        code, report = self.run_unittest_skip(all_skipped=True)
        self.assertEqual(code, 1)
        self.assertEqual(report['tests_passed'], 0)
        self.assertTrue(report['skipped_tests'])

    def test_unittest_individual_skip_without_summary_is_still_critical(self):
        code = self.run_text('verifier_tests',
            "test_contract (fixture.Contract.test_contract) ... skipped 'unavailable'\nRan 1 test in 0.001s\nOK")
        self.assertEqual(code, 1)
        report = json.loads((self.root / 'verifier_tests.json').read_text())
        self.assertEqual(report['tests_passed'], 0)

    def run_text(self, name, output):
        command = [sys.executable, '-c', 'print(' + repr(output) + ')']
        with patch.object(checks, 'source_identity', return_value=(SHA, DIRTY)):
            with contextlib.redirect_stdout(io.StringIO()):
                return checks.run_check(self.root, self.root, name, command)

    def test_rust_ignored_test_is_a_critical_skip(self):
        self.assertEqual(self.run_text('rust_tests',
            'test result: ok. 12 passed; 0 failed; 1 ignored; 0 measured'), 1)

    def test_node_tap_skip_is_a_critical_skip(self):
        self.assertEqual(self.run_text('c_tests', '# pass 12\n# skipped 1'), 1)

    def test_xctest_skip_is_a_critical_skip(self):
        self.assertEqual(self.run_text('runner_tests',
            'Executed 3 tests, with 1 test skipped and 0 failures'), 1)

    def test_non_machine_test_check_requires_nonzero_test_count(self):
        self.assertEqual(self.run_text('c_tests', '# pass 0\n# skipped 0'), 1)

    def test_non_machine_successful_test_count_is_recorded(self):
        self.assertEqual(self.run_text('c_tests', '# pass 12\n# skipped 0'), 0)
        report = json.loads((self.root / 'c_tests.json').read_text())
        self.assertEqual(report['tests_passed'], 12)

    def run_machine(self, name, events):
        command = [sys.executable, '-c',
                   'import json; events=' + repr(events) +
                   '; [print(json.dumps(event)) for event in events]']
        with patch.object(checks, 'source_identity', return_value=(SHA, DIRTY)):
            with contextlib.redirect_stdout(io.StringIO()):
                return checks.run_check(self.root, self.root, name, command)

    def test_machine_check_without_any_test_evidence_fails(self):
        self.assertEqual(self.run_machine('frb_host_tests', []), 1)

    def test_machine_check_requires_successful_completion(self):
        events = [{'type': 'testStart', 'test': {'id': 1, 'name': 'health'}},
                  {'type': 'testDone', 'testID': 1, 'skipped': False, 'result': 'success'}]
        self.assertEqual(self.run_machine('ios_acceptance', events), 1)

    def test_machine_pass_is_recorded_without_raw_output(self):
        events = [{'type': 'testStart', 'test': {'id': 1, 'name': 'health'}},
                  {'type': 'testDone', 'testID': 1, 'skipped': False, 'result': 'success'},
                  {'type': 'done', 'success': True}]
        self.assertEqual(self.run_machine('frb_host_tests', events), 0)
        report = json.loads((self.root / 'frb_host_tests.json').read_text())
        self.assertEqual(report['tests_passed'], 1)
        self.assertNotIn('output', report)

    def test_any_host_skip_is_critical(self):
        events = [{'type': 'testStart', 'test': {'id': 1, 'name': 'health'}},
                  {'type': 'testDone', 'testID': 1, 'skipped': True, 'result': 'success'},
                  {'type': 'done', 'success': True}]
        self.assertEqual(self.run_machine('frb_host_tests', events), 1)
        report = json.loads((self.root / 'frb_host_tests.json').read_text())
        self.assertEqual(report['critical_skips'], ['health'])


if __name__ == '__main__':
    unittest.main()
