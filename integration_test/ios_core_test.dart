import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/src/rust/api.dart' as rust;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS static core initializes, requests, cancels, shuts down and restarts',
    (tester) async {
      expect(Platform.isIOS, isTrue, reason: 'must execute inside an iOS app');
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('fqapp-ios-core-');
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final arrived = Completer<void>();
        final release = Completer<void>();
        upstream.listen((request) async {
          if (!arrived.isCompleted) arrived.complete();
          await release.future;
          try {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"code":0,"data":{}}');
            await request.response.close();
          } on IOException {
            // The cancellation under test has already closed the socket.
          }
        });
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await rust.shutdown();
          await upstream.close(force: true);
          await root.delete(recursive: true);
        });
        await File('${root.path}/config.json').writeAsString(
          '{"algorithm_type":"8404","port":0,"anti_crawler":{"enabled":false}}',
        );
        await File('${root.path}/pool.json').writeAsString(
          jsonEncode({
            'android': [
              for (var i = 0; i < 5; i++)
                {
                  'device_id': i.toString().padLeft(16, '0'),
                  'install_id': '${9000000000000000000 + i}',
                  'secret_key': i.toRadixString(16).padLeft(32, '0'),
                  'platform': 'android',
                  'status': 'active',
                  'created_time': '2026-01-01 00:00:00',
                  'last_used': '2026-01-01 00:00:00',
                  'use_count': i,
                  'cdid': 'offline-fixture-$i',
                },
            ],
            'last_update': '2026-01-01 00:00:00',
          }),
        );
        await RustBackendTransport.ensureRuntime();
        await RustBackendTransport.ensureRuntime();
        Future<String> start() => rust.init(
          configPath: '${root.path}/config.json',
          poolPath: '${root.path}/pool.json',
          filterPath: '${root.path}/filter.json',
          runtimeDir: root.path,
          port: 0,
          mockUpstreamOrigin: 'http://127.0.0.1:${upstream.port}',
        );
        Future<rust.BridgeResponse> request(String id, String path) =>
            rust.request(
              requestId: id,
              method: 'GET',
              path: path,
              query: '',
              body: Uint8List(0),
              timeoutMs: 5000,
            );
        expect(await start(), 'running');
        expect(await rust.status(), 'running');
        final health = await request('ios-health', '/health');
        expect(health.status, 200);
        expect(jsonDecode(utf8.decode(health.body))['status'], 'ok');
        final pending = request(
          'ios-cancel',
          '/api/v1/items/7507512821328904729',
        );
        await arrived.future.timeout(const Duration(seconds: 5));
        expect(await rust.cancel(requestId: 'ios-cancel'), isTrue);
        expect((await pending.timeout(const Duration(seconds: 3))).status, 499);
        expect(await rust.cancel(requestId: 'ios-cancel'), isFalse);
        await rust.shutdown();
        expect(await rust.status(), 'starting');
        expect(await rust.baseUrl(), isEmpty);
        expect(await start(), 'running');
        expect((await request('ios-restart', '/health')).status, 200);
        await rust.shutdown();
        expect(await rust.status(), 'starting');
      });
    },
  );
}
