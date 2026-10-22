import 'dart:async';

import 'package:flutter/widgets.dart';

/// Coordinates process-wide work; owns no page state or player lifetime.
class IosLifecycle {
  IosLifecycle({
    required this.pauseDownloads,
    required this.flushProgress,
    required this.backgroundPlaybackAllowed,
    required this.pausePlayback,
    required this.ensureCore,
  });

  final Future<void> Function() pauseDownloads;
  final Future<void> Function() flushProgress;
  final FutureOr<bool> Function() backgroundPlaybackAllowed;
  final Future<void> Function() pausePlayback;
  final Future<void> Function() ensureCore;

  Future<void> _pending = Future<void>.value();
  bool _background = false;

  Future<void> onState(AppLifecycleState state) {
    final operation = _pending.then((_) => _transition(state));
    // A failed transition is reported to its caller, but never poisons the
    // queue: foreground recovery and explicit retries must still be possible.
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _transition(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      await ensureCore();
      _background = false;
      return;
    }
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    if (_background) return;
    _background = true;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await attempt(pauseDownloads);
    await attempt(() async {
      // Query failure is not evidence that native PiP/audio stopped. Preserve
      // its ownership, report the error, and still flush ordinary progress.
      if (!await backgroundPlaybackAllowed()) await pausePlayback();
    });
    await attempt(flushProgress);
    if (firstError != null) {
      _background = false;
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }
}
