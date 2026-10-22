import 'dart:convert';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final payload = data?['fqapp_integration'];
    if (payload is! Map ||
        payload['schema_version'] != 1 ||
        payload['entry'] != 'ios_acceptance') {
      throw StateError('Missing actual iOS acceptance result inventory');
    }
    final expected = payload['expected_tests'];
    final results = payload['results'];
    const required = {
      'cold bootstrap reaches the packaged Rust core health endpoint',
      'search to detail to reading persists progress and reopens offline',
      'media controls preserve play pause and seek state with injected adapter',
    };
    // This is actual IntegrationTestWidgetsFlutterBinding.results, not an
    // invented Flutter test-runner event. Skipped bodies have no result entry.
    // CLI contract consumed by the check recorder.
    // ignore: avoid_print
    print(jsonEncode({'type': 'fqapp.integration.result', ...payload}));
    if (expected is! List ||
        expected.length != required.length ||
        expected.toSet().difference(required).isNotEmpty ||
        results is! Map ||
        results.length != required.length ||
        !required.every((name) => results[name] == 'success')) {
      throw StateError('Missing, skipped or failed iOS acceptance test');
    }
  },
);
