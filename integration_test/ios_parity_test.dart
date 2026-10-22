import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/ios_media_bridge.dart';
import 'package:fqapp/services/ios_storage_protection.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/src/rust/api.dart' as rust;
import 'package:fqapp/src/rust/api/media.dart' as media;
import 'package:fqapp/widgets/player/platform_video_surface.dart';
import 'ios_core_test.dart' as core;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  core.main();
  testWidgets(
    'local iOS plugins, AVPlayer first frame and Rust lease release',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      const encoded = String.fromEnvironment('FQAPP_IOS_FIXTURES');
      expect(
        encoded,
        isNotEmpty,
        reason: 'Supply synthetic fixtures through an ignored define file',
      );
      final fixtures = (jsonDecode(encoded) as List)
          .cast<Map<String, dynamic>>();
      expect(fixtures.length, greaterThanOrEqualTo(3));
      await IosStorageProtection.configure();
      const rawStorage = FlutterSecureStorage();
      final secureStorage = FlutterSecureKeyStorage(rawStorage);
      final fixtureKey =
          'fqapp_test_only_${DateTime.now().microsecondsSinceEpoch}';
      addTearDown(
        () => rawStorage.delete(
          key: fixtureKey,
          iOptions: const IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
            synchronizable: false,
          ),
        ),
      );
      await secureStorage.write(fixtureKey, 'synthetic-nonsecret');
      expect(await secureStorage.read(fixtureKey), 'synthetic-nonsecret');
      const reader = MethodChannel('fqapp/reader');
      final readerStatus = await reader.invokeMapMethod<String, dynamic>(
        'start',
        {'session': 'parity-reader', 'brightness': -1.0},
      );
      expect(readerStatus?['timestamp'], isA<int>());
      await reader.invokeMethod<void>('setImmersive', {
        'session': 'parity-reader',
        'enabled': true,
      });
      await reader.invokeMethod<void>('stop', {'session': 'parity-reader'});
      final voices = await const MethodChannel(
        'fqapp/system_tts',
      ).invokeMapMethod<String, dynamic>('engines');
      expect(voices?['engines'], isA<List>());

      // No system sheets or real account interactions in this probe.
      expect(
        await const MethodChannel(
          'fqapp/share',
        ).invokeMethod<bool>('shareText', {'text': ''}),
        false,
      );
      await const MethodChannel(
        'fqapp/fanqie_account',
      ).invokeMethod<void>('cancelLogin');
      expect(await NativePlayer.systemPlaybackActive(), false);
      await NativePlayer.canDrawOverlays();
      final root = await Directory.systemTemp.createTemp('fqapp-ios-media-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"code":0,"data":{}}');
        await request.response.close();
      });
      addTearDown(() async {
        await rust.shutdown();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      });
      await File('${root.path}/config.json').writeAsString(
        '{"algorithm_type":"8404","anti_crawler":{"enabled":false}}',
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
                'cdid': 'synthetic-fixture-$i',
              },
          ],
          'last_update': '2026-01-01 00:00:00',
        }),
      );
      await RustBackendTransport.ensureRuntime();
      expect(
        await rust.init(
          configPath: '${root.path}/config.json',
          poolPath: '${root.path}/pool.json',
          filterPath: '${root.path}/filter.json',
          runtimeDir: root.path,
          port: 0,
          mockUpstreamOrigin: 'http://127.0.0.1:${upstream.port}',
        ),
        'running',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> status(String url) async {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('Range', 'bytes=0-31');
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      for (var index = 0; index < fixtures.length; index++) {
        final fixture = fixtures[index];
        final file = File('${root.path}/fixture-$index.mp4');
        await file.writeAsBytes(
          base64Decode(fixture['bytesBase64'] as String),
          flush: true,
        );
        late media.MediaSession lease;
        final released = Completer<void>();
        final bridge = IosMediaBridge(
          create: ({required requestId, required source, key}) async {
            lease = await media.mediaCreate(
              requestId: requestId,
              source: source,
              key: key,
            );
            return lease;
          },
          close: ({required session}) async {
            await media.mediaClose(session: session);
            if (!released.isCompleted) released.complete();
          },
        );
        final player = NativePlayer(mediaBridge: bridge);
        final errors = <Object>[];
        final observation = player.errorStream.listen(errors.add);
        try {
          await player.create(
            file.uri.toString(),
            fixture['keyHex'] as String? ?? '',
          );
          expect(await status(lease.playbackUrl), 206);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  height: 240,
                  child: PlatformVideoSurface(surface: player.surface!),
                ),
              ),
            ),
          );
          await player.play();
          final deadline = DateTime.now().add(const Duration(seconds: 25));
          while (!player.firstFrameRendered &&
              errors.isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            errors,
            isEmpty,
            reason:
                'Synthetic fixture $index (${fixture['name']}): native error '
                'codes ${errors.map((error) => error is NativePlaybackException ? error.errorCode : null).toList()}',
          );
          expect(
            player.firstFrameRendered,
            true,
            reason: 'Real AVPlayerLayer frame for synthetic fixture $index',
          );
          expect(player.duration, greaterThan(Duration.zero));
          await player.seek(const Duration(milliseconds: 500));
          await player.pause();
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          await player.dispose();
          await observation.cancel();
        }
        await released.future.timeout(const Duration(seconds: 5));
        expect(await status(lease.playbackUrl), 404);
        final cancelledId = 'cancel-before-open-$index';
        expect(await media.mediaCancel(requestId: cancelledId), false);
        await expectLater(
          media.mediaCreate(
            requestId: cancelledId,
            source: media.MediaSource.localFile(path: file.path),
          ),
          throwsA(
            isA<media.MediaError>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // Registered after the SDK teardown so this runs first and reports only tests
  // that actually ran; skipped tests are absent from binding.results.
  tearDownAll(() {
    binding.reportData = {
      ...?binding.reportData,
      'fqapp_integration': {
        'schema_version': 1,
        'entry': 'ios_native_media',
        'expected_tests': [
          'iOS static core initializes, requests, cancels, shuts down and restarts',
          'local iOS plugins, AVPlayer first frame and Rust lease release',
        ],
        'results': {
          for (final result in binding.results.entries)
            result.key: result.value == 'success' ? 'success' : 'failed',
        },
      },
    };
  });
}
