import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/ios_media_bridge.dart';
import 'package:fqapp/src/rust/api/media.dart';
import 'package:fqapp/services/player_surface.dart';
import 'package:fqapp/widgets/player/platform_video_surface.dart';

void main() {
  test('uncreated player exposes no typed surface', () {
    expect(NativePlayer().surface, isNull);
  });
  test(
    'media bridge maps remote/local sources and decodes content key',
    () async {
      final sources = <MediaSource>[];
      final keys = <List<int>?>[];
      final closed = <MediaSessionRef>[];
      final reference = MediaSessionRef(
        id: 'fixture',
        generation: BigInt.from(8),
      );
      final bridge = IosMediaBridge(
        create: ({required requestId, required source, key}) async {
          sources.add(source);
          keys.add(key);
          return MediaSession(
            session: reference,
            playbackUrl: 'http://127.0.0.1:8080/_session/fixture/media/fixture',
            contentLength: BigInt.from(1),
            contentType: 'video/mp4',
          );
        },
        cancel: ({required requestId}) async => true,
        close: ({required session}) async {
          closed.add(session);
        },
      );
      final remote = await bridge.open(
        'https://example.invalid/video',
        '00aF',
        requestId: 'a',
      );
      final local = await bridge.open(
        'file:///tmp/video%20file.mp4',
        '',
        requestId: 'b',
      );
      expect(
        (sources[0] as MediaSource_RemoteHttps).url,
        'https://example.invalid/video',
      );
      expect((sources[1] as MediaSource_LocalFile).path, '/tmp/video file.mp4');
      expect(keys, [
        [0, 175],
        null,
      ]);
      bridge.bind(71, remote);
      await bridge.releasePlayer(71);
      await bridge.releasePlayer(71);
      await bridge.close(remote);
      expect(closed, [reference]);
      await bridge.close(local);
    },
  );

  test(
    'invalid playback URL closes created lease before rejecting it',
    () async {
      var closes = 0;
      final bridge = IosMediaBridge(
        create: ({required requestId, required source, key}) async {
          return MediaSession(
            session: MediaSessionRef(id: 'fixture', generation: BigInt.one),
            playbackUrl: 'https://remote.invalid/capability',
            contentLength: BigInt.one,
            contentType: 'video/mp4',
          );
        },
        close: ({required session}) async {
          closes++;
        },
      );
      await expectLater(
        bridge.open('/tmp/video.mp4', '', requestId: 'invalid'),
        throwsStateError,
      );
      expect(closes, 1);
    },
  );

  testWidgets('legacy surface uses its texture handle', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PlatformVideoSurface(surface: TexturePlayerSurface(9)),
      ),
    );
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 9);
    expect(find.byType(UiKitView), findsNothing);
  });
  testWidgets('passive iOS video surface forwards taps to Flutter controls', (
    tester,
  ) async {
    // Only the unavailable native engine boundary is mocked. The production
    // widget and Flutter's platform-view hit testing handle the actual tap.
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    var taps = 0;
    try {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
              ),
              const PlatformVideoSurface(surface: IosPlayerSurface(71)),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byType(PlatformVideoSurface)));
      await tester.pump();
      expect(
        taps,
        1,
        reason:
            'A passive AVPlayerLayer must not consume Flutter controls taps',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    }
  });

  testWidgets('iOS surface sends playerId to the platform view', (
    tester,
  ) async {
    // Inspect this boundary without creating an unavailable UIKit engine in
    // the host tester. Native attachment is exercised by RunnerTests.
    late Widget built;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          built = const PlatformVideoSurface(
            surface: IosPlayerSurface(71),
          ).build(context);
          return const SizedBox();
        },
      ),
    );
    final view = built as UiKitView;
    expect(view.viewType, 'fqapp/player');
    expect(view.creationParams, {'playerId': 71});
    expect(view.creationParamsCodec, isA<StandardMessageCodec>());
  });
}
