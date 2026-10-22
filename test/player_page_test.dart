import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/pages/listen_mode_page.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/system_playback_session.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  for (final pip in [false, true]) {
    testWidgets('mounted iOS system stop releases once (PiP: $pip)', (
      tester,
    ) async {
      final harness = await _mountIOS(tester);
      try {
        if (pip) await harness.startPiP(tester);
        await _remote('stop');
        await _flush(tester);
        await _remote('stop');
        await _flush(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _flush(tester);
        expect(
          harness.players.first.calls.where((call) => call == 'dispose'),
          hasLength(1),
        );
        expect(
          harness.players.first.calls.where((call) => call == 'released'),
          hasLength(1),
        );
        expect(
          tester
              .widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome))
              .player,
          isNull,
        );
        expect(SystemPlaybackRegistry.find('video:mounted-book'), isNull);
        expect(find.byType(PlayerPage), findsOneWidget);
      } finally {
        await harness.close(tester);
      }
    });
  }

  testWidgets(
    'mounted iOS PiP completion transfers before releasing old host',
    (tester) async {
      final harness = await _mountIOS(tester);
      try {
        await harness.startPiP(tester);
        harness.players.first.emitCompleted();
        for (var i = 0; i < 8; i++) {
          await _flush(tester);
        }
        expect(harness.players, hasLength(2));
        expect(harness.events, contains('swap:2'));
        expect(
          harness.events.indexOf('swap:2'),
          lessThan(harness.events.indexOf('release:1')),
        );
        expect(harness.events, isNot(contains('stopFloating')));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _flush(tester);
        final chrome = tester.widget<VideoPlayerChrome>(
          find.byType(VideoPlayerChrome),
        );
        expect(chrome.currentIndex, 1);
        expect(chrome.player, same(harness.players.last));
        expect(find.byType(PlayerPage), findsOneWidget);
      } finally {
        await harness.close(tester);
      }
    },
  );

  for (final leavePage in [false, true]) {
    testWidgets(
      'iOS PiP keeps new owner while old dispose waits (leave: $leavePage)',
      (tester) async {
        final harness = await _mountIOS(tester);
        final oldRelease = Completer<void>();
        try {
          await harness.startPiP(tester);
          harness.players.first.releaseGate = oldRelease;
          harness.players.first.emitCompleted();
          for (var i = 0; i < 8; i++) {
            await _flush(tester);
          }
          expect(harness.players, hasLength(2));
          final incoming = harness.players.last;
          final session =
              SystemPlaybackRegistry.find('video:mounted-book')
                  as RetainedPlaybackSession;
          expect(session.player, same(incoming));
          expect(harness.players.first.calls, contains('dispose'));
          expect(harness.players.first.calls, isNot(contains('released')));
          if (leavePage) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await _flush(tester);
            expect(SystemPlaybackRegistry.find(session.id), same(session));
            expect(session.player, same(incoming));
            expect(session.index, 1);
            expect(incoming.disposed, isFalse);
            expect(incoming.playWhenReady, isTrue);
          } else {
            await _remote('stop');
            for (var i = 0; i < 4; i++) {
              await _flush(tester);
            }
            expect(incoming.disposed, isTrue);
            expect(
              incoming.calls.where((call) => call == 'dispose'),
              hasLength(1),
            );
            expect(SystemPlaybackRegistry.find(session.id), isNull);
          }
          oldRelease.complete();
          await session.settled;
          expect(session.player, same(incoming));
          expect(incoming.disposed, !leavePage);
        } finally {
          if (!oldRelease.isCompleted) oldRelease.complete();
          await harness.close(tester);
          // A failing ownership assertion must not leak its orphan fixture.
          for (final player in harness.players) {
            await player.dispose();
          }
        }
      },
    );
  }

  testWidgets('iOS foreground reload replaces the ended PiP session owner', (
    tester,
  ) async {
    final harness = await _mountIOS(tester);
    try {
      await harness.startPiP(tester);
      final previous =
          SystemPlaybackRegistry.find('video:mounted-book')
              as RetainedPlaybackSession;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _remote('fullscreen');
      await _flush(tester);
      await _remote('next');
      for (var i = 0; i < 8; i++) {
        await _flush(tester);
      }
      expect(previous.closed, isTrue);
      expect(harness.players.first.disposed, isTrue);
      expect(harness.players.last.disposed, isFalse);
      expect(SystemPlaybackRegistry.find(previous.id), isNull);
      await harness.startPiP(tester);
      final replacement =
          SystemPlaybackRegistry.find(previous.id) as RetainedPlaybackSession;
      expect(replacement, isNot(same(previous)));
      expect(replacement.player, same(harness.players.last));
      expect(replacement.index, 1);
    } finally {
      await harness.close(tester);
    }
  });

  testWidgets('mounted iOS PiP failed transfer retains the old host', (
    tester,
  ) async {
    final harness = await _mountIOS(tester);
    try {
      await harness.startPiP(tester);
      harness.failSwap = true;
      await _remote('next');
      for (var i = 0; i < 8; i++) {
        await _flush(tester);
      }
      expect(harness.players, hasLength(2));
      expect(harness.players.first.disposed, isFalse);
      expect(harness.players.last.disposed, isTrue);
      expect(harness.events, isNot(contains('stopFloating')));
      final session =
          SystemPlaybackRegistry.find('video:mounted-book')
              as RetainedPlaybackSession;
      expect(session.error, isA<PlatformException>());
      expect(session.player, same(harness.players.first));
      harness.failSwap = false;
      await _remote('next');
      for (var i = 0; i < 8; i++) {
        await _flush(tester);
      }
      expect(session.index, 1);
      expect(harness.players.first.disposed, isTrue);
    } finally {
      await harness.close(tester);
    }
  });

  testWidgets(
    'iOS listening return hands pause and next back to mounted video',
    (tester) async {
      final harness = await _mountIOS(tester, shortSeries: true);
      try {
        tester
            .widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome))
            .onOpenListenMode!();
        for (var i = 0; i < 6; i++) {
          await _flush(tester);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(ListenModePage), findsOneWidget);
        expect(harness.players, hasLength(2));
        await tester.tap(find.byKey(const ValueKey('listen-page-back')));
        for (var i = 0; i < 6; i++) {
          await _flush(tester);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(harness.players.first.playWhenReady, isTrue);
        await _remote('pause');
        await _flush(tester);
        expect(harness.players.first.playWhenReady, isFalse);
        expect(harness.players[1].disposed, isTrue);
        expect(SystemPlaybackRegistry.find('listen:mounted-book'), isNull);
        await _remote('next');
        for (var i = 0; i < 8; i++) {
          await _flush(tester);
        }
        expect(
          tester
              .widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome))
              .currentIndex,
          1,
        );
        expect(harness.players, hasLength(3));
        expect(harness.players.last.playWhenReady, isTrue);
      } finally {
        await harness.close(tester);
      }
    },
  );

  testWidgets(
    'visible Windows window autoplays while it has no keyboard focus',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final player = ControlledNativePlayer();
      try {
        await tester.pumpWidget(
          _app(store: ControlledReaderStore(), player: player),
        );
        await _flush(tester);
        expect(player.isPlaying, isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await _flush(tester);
        expect(player.isPlaying, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await _flush(tester);
        expect(player.isPlaying, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('playback statistics reject restore and seek jumps', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.setSurfaceSize(null);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final store = ControlledReaderStore();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    await tester.pumpWidget(_app(store: store, player: player));
    await _flush(tester);
    expect(player.isPlaying, isTrue);

    // A restore/seek jump must never be counted as newly watched time.
    player.emitPosition(const Duration(seconds: 300));
    await _flush(tester);

    // The production accumulator is a Stopwatch, so only real wall-clock
    // playback advances it; the virtual test clock above does not.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);

    expect(store.entry?['position'], 300);
    expect(store.seconds, greaterThan(0));
    expect(store.seconds, lessThan(30));

    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

Widget _app({
  required ControlledReaderStore store,
  required ControlledNativePlayer player,
}) => MaterialApp(
  home: PlayerPage(
    bookId: 'stats-book',
    title: '统计测试',
    eps: [
      Chapter(itemId: '1', title: '第 1 集', volumeName: ''),
      Chapter(itemId: '2', title: '第 2 集', volumeName: ''),
    ],
    startIndex: 0,
    historyStore: store,
    contentLoader: (chapter) async => _source(chapter.itemId),
    playerFactory: () => player,
  ),
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

class _MountedPlayer extends ControlledNativePlayer {
  _MountedPlayer(this.id, this.events);
  final int id;
  final List<String> events;
  @override
  int? get playerId => isCreated ? id : null;
  @override
  Future<void> dispose() {
    if (!disposed) events.add('release:$id');
    return super.dispose();
  }
}

class _Harness {
  final players = <_MountedPlayer>[];
  final events = <String>[];
  bool failSwap = false;
  Future<void> close(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await SystemPlaybackRegistry.closeAll();
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
    debugDefaultTargetPlatformOverride = null;
    PlayerPreferences.resetFloatingWindowForTest();
  }

  _MountedPlayer create() {
    final player = _MountedPlayer(players.length + 1, events);
    players.add(player);
    return player;
  }

  Future<void> startPiP(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    for (var i = 0; i < 4; i++) {
      await _flush(tester);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);
    expect(events, contains('startFloating'));
  }
}

Future<_Harness> _mountIOS(
  WidgetTester tester, {
  bool shortSeries = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  PlayerPreferences.resetFloatingWindowForTest();
  AudioPreferences.instance.resetForTest();
  SharedPreferences.setMockInitialValues({
    'player_floating_window_enabled': true,
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.binding.setSurfaceSize(const Size(400, 800));
  final harness = _Harness();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('fqapp/native_player'), (
        call,
      ) async {
        if (call.method == 'canDrawOverlays') return true;
        if (call.method == 'swapFloatingPlayer') {
          harness.events.add('swap:${(call.arguments as Map)['playerId']}');
          if (harness.failSwap) {
            throw PlatformException(code: 'pip_swap_failed');
          }
        } else {
          harness.events.add(call.method);
        }
        return null;
      });
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        bookId: 'mounted-book',
        title: 'Mounted',
        shortSeries: shortSeries,
        eps: [
          Chapter(itemId: '1', title: 'First', volumeName: ''),
          Chapter(itemId: '2', title: 'Second', volumeName: ''),
        ],
        startIndex: 0,
        historyStore: ControlledReaderStore(),
        contentLoader: (chapter) async => _source(chapter.itemId),
        playerFactory: harness.create,
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await _flush(tester);
  }
  expect(harness.players.first.playWhenReady, isTrue);
  return harness;
}

Future<void> _remote(String action) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'fqapp/native_player',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onNotificationAction', {'action': action}),
        ),
        (_) => done.complete(),
      );
  await done.future;
}
