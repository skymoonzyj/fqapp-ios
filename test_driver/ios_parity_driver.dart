import 'dart:convert';
import 'package:integration_test/integration_test_driver.dart';

const _requiredTests = {
  'iOS static core initializes, requests, cancels, shuts down and restarts',
  'local iOS plugins, AVPlayer first frame and Rust lease release',
};

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) {
    final payload = data?['fqapp_integration'];
    if (payload is! Map ||
        payload['schema_version'] != 1 ||
        payload['entry'] != 'ios_native_media' ||
        payload['expected_tests'] is! List ||
        payload['results'] is! Map) {
      throw StateError('Missing actual iOS integration results');
    }
    final expected = (payload['expected_tests'] as List).toSet();
    final results = payload['results'] as Map;
    // This is our result record, not a synthetic Flutter machine event.
    // ignore: avoid_print
    print(jsonEncode({'type': 'fqapp.integration.result', ...payload}));
    if (expected.length != _requiredTests.length ||
        !expected.containsAll(_requiredTests) ||
        results.length != _requiredTests.length ||
        !_requiredTests.every((name) => results[name] == 'success')) {
      throw StateError(
        'Required iOS tests failed, skipped, or did not execute',
      );
    }
  },
);
