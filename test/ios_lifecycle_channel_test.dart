import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/ios_lifecycle.dart';
import 'package:fqapp/services/native_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/native_player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final failure in ['channel error', 'missing result']) {
    test(
      'real native $failure preserves playback while downloads and progress settle',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'systemPlaybackActive');
          if (failure == 'channel error') {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });
        final effects = <String>[];
        final lifecycle = IosLifecycle(
          pauseDownloads: () async => effects.add('downloads'),
          flushProgress: () async => effects.add('flush'),
          backgroundPlaybackAllowed: () =>
              NativePlayer.systemPlaybackActive(throwOnError: true),
          pausePlayback: () async => effects.add('playback'),
          ensureCore: () async => effects.add('resume'),
        );
        await expectLater(
          lifecycle.onState(AppLifecycleState.paused),
          throwsA(isA<PlatformException>()),
        );
        expect(effects, ['downloads', 'flush']);
        await lifecycle.onState(AppLifecycleState.resumed);
        expect(effects.last, 'resume');
        expect(
          await NativePlayer.systemPlaybackActive(),
          false,
          reason: 'Existing best-effort caller compatibility',
        );
      },
    );
  }

  for (final active in [false, true]) {
    test(
      'real native explicit $active controls lifecycle playback pause',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async => active);
        final effects = <String>[];
        final lifecycle = IosLifecycle(
          pauseDownloads: () async => effects.add('downloads'),
          flushProgress: () async => effects.add('flush'),
          backgroundPlaybackAllowed: () =>
              NativePlayer.systemPlaybackActive(throwOnError: true),
          pausePlayback: () async => effects.add('playback'),
          ensureCore: () async {},
        );
        await lifecycle.onState(AppLifecycleState.paused);
        expect(
          effects,
          active ? ['downloads', 'flush'] : ['downloads', 'playback', 'flush'],
        );
      },
    );
  }
}
