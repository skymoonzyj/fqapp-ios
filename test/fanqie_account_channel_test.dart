import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/fanqie_library_capture_service.dart';
import 'package:fqapp/services/platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => PlatformChannels.invoke = null);

  test(
    'cancelled login returns without starting collection or waiting for cookies',
    () => withoutCaptureAPI(() async {
      final login = Completer<String?>();
      final calls = <String>[];
      final progress = <String>[];
      PlatformChannels.invoke = (channel, method, arguments) async {
        calls.add('$channel/$method');
        if (method == 'login') return login.future;
        if (method == 'cancelLogin') return null;
        fail('Cancelled login must not store or export a capture');
      };
      final request = BackendRequest();
      final pending = FanqieLibraryCaptureService().collect(
        request,
        progress.add,
      );
      request.cancel();
      expect(await pending.timeout(const Duration(milliseconds: 200)), isNull);
      login.complete('sessionid=late-fixture');
      await Future<void>.delayed(Duration.zero);
      expect(progress, isEmpty);
      expect(calls, [
        'fqapp/fanqie_account/login',
        'fqapp/fanqie_account/cancelLogin',
      ]);
    }),
  );

  test('already cancelled request never opens a login window', () async {
    final calls = <String>[];
    PlatformChannels.invoke = (channel, method, arguments) async {
      calls.add(method);
      return null;
    };
    final request = BackendRequest()..cancel();
    expect(
      await FanqieLibraryCaptureService().collect(request, (_) {}),
      isNull,
    );
    expect(calls, isEmpty);
  });

  test('user closes official login without invoking collection APIs', () async {
    final calls = <String>[];
    final progress = <String>[];
    PlatformChannels.invoke = (channel, method, arguments) async {
      calls.add('$channel/$method');
      return null;
    };
    expect(
      await FanqieLibraryCaptureService().collect(
        BackendRequest(),
        progress.add,
      ),
      isNull,
    );
    expect(progress, isEmpty);
    expect(calls, ['fqapp/fanqie_account/login']);
  });
}

// Keep the real collector and ApiClient boundary; replace only external HTTP.
Future<void> withoutCaptureAPI(Future<void> Function() action) async {
  var requests = 0;
  final client = MockClient((_) async {
    requests++;
    return http.Response('{}', 500);
  });
  try {
    await http.runWithClient(action, () => client);
    expect(
      requests,
      0,
      reason: 'Cancellation must never issue a collection API request',
    );
  } finally {
    client.close();
  }
}
