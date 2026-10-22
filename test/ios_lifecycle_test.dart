import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/ios_lifecycle.dart';

void main() {
  test(
    'awaits an asynchronous native continuation query before deciding to pause',
    () async {
      final probe = Completer<bool>();
      final effects = <String>[];
      final lifecycle = IosLifecycle(
        pauseDownloads: () async => effects.add('downloads paused'),
        flushProgress: () async => effects.add('progress persisted'),
        backgroundPlaybackAllowed: () => probe.future,
        pausePlayback: () async => effects.add('playback paused'),
        ensureCore: () async {},
      );
      final transition = lifecycle.onState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(effects, ['downloads paused']);
      probe.complete(true);
      await transition;
      expect(effects, ['downloads paused', 'progress persisted']);
    },
  );

  test(
    'a native playback probe failure still persists progress without stopping playback',
    () async {
      final effects = <String>[];
      final lifecycle = IosLifecycle(
        pauseDownloads: () async => effects.add('downloads paused'),
        flushProgress: () async => effects.add('progress persisted'),
        backgroundPlaybackAllowed: () =>
            throw StateError('native probe unavailable'),
        pausePlayback: () async => effects.add('playback paused'),
        ensureCore: () async {},
      );
      await expectLater(
        lifecycle.onState(AppLifecycleState.paused),
        throwsStateError,
      );
      expect(effects, ['downloads paused', 'progress persisted']);
    },
  );

  test(
    'background pauses ordinary downloads and flushes without ending adopted playback',
    () async {
      final effects = <String>[];
      final lifecycle = IosLifecycle(
        pauseDownloads: () async => effects.add('downloads paused'),
        flushProgress: () async => effects.add('progress persisted'),
        backgroundPlaybackAllowed: () => true,
        pausePlayback: () async => effects.add('playback paused'),
        ensureCore: () async => effects.add('core ready'),
      );
      await lifecycle.onState(AppLifecycleState.inactive);
      expect(effects, isEmpty);
      await lifecycle.onState(AppLifecycleState.hidden);
      await lifecycle.onState(AppLifecycleState.paused);
      expect(effects, ['downloads paused', 'progress persisted']);
      await lifecycle.onState(AppLifecycleState.resumed);
      expect(effects.last, 'core ready');
      // Downloads stay explicitly paused so a cellular reconnect cannot resume
      // an unbounded download behind the user's existing network preference.
      expect(effects.length, 3);
    },
  );

  test(
    'background-disabled playback pauses while progress still persists',
    () async {
      final effects = <String>[];
      final lifecycle = IosLifecycle(
        pauseDownloads: () async => effects.add('downloads paused'),
        flushProgress: () async => effects.add('progress persisted'),
        backgroundPlaybackAllowed: () => false,
        pausePlayback: () async => effects.add('playback paused'),
        ensureCore: () async {},
      );
      await lifecycle.onState(AppLifecycleState.paused);
      expect(effects, [
        'downloads paused',
        'playback paused',
        'progress persisted',
      ]);
    },
  );

  test(
    'quick foreground transition waits for pause and flush before core recovery',
    () async {
      final finishPause = Completer<void>();
      final effects = <String>[];
      final lifecycle = IosLifecycle(
        pauseDownloads: () => finishPause.future,
        flushProgress: () async => effects.add('flushed'),
        backgroundPlaybackAllowed: () => true,
        pausePlayback: () async {},
        ensureCore: () async => effects.add('ready'),
      );
      final background = lifecycle.onState(AppLifecycleState.paused);
      final foreground = lifecycle.onState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(effects, isEmpty);
      finishPause.complete();
      await Future.wait([background, foreground]);
      expect(effects, ['flushed', 'ready']);
    },
  );

  test(
    'pause failure still flushes and a later foreground can retry recovery',
    () async {
      final effects = <String>[];
      var recoveryAttempts = 0;
      final lifecycle = IosLifecycle(
        pauseDownloads: () async => throw StateError('download close failed'),
        flushProgress: () async => effects.add('flushed'),
        backgroundPlaybackAllowed: () => true,
        pausePlayback: () async {},
        ensureCore: () async {
          recoveryAttempts++;
          if (recoveryAttempts == 1) throw StateError('core unavailable');
          effects.add('ready');
        },
      );
      await expectLater(
        lifecycle.onState(AppLifecycleState.paused),
        throwsStateError,
      );
      expect(effects, ['flushed']);
      await expectLater(
        lifecycle.onState(AppLifecycleState.resumed),
        throwsStateError,
      );
      await lifecycle.onState(AppLifecycleState.resumed);
      expect(effects, ['flushed', 'ready']);
    },
  );
}
