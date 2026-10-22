import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/listen_mode_page.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/system_playback_session.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'support/controlled_player.dart';

class _Session implements SystemPlaybackSession {
  _Session(this.id);
  @override
  final String id;
  int closes = 0;
  final commands = <String>[];
  Completer<void>? closing;
  @override
  Future<void> handleCommand(String action) async => commands.add(action);
  @override
  Future<void> close() async {
    closes++;
    await closing?.future;
  }
}

void main() {
  testWidgets(
    'iOS chrome leaves background playback and resume to native owner',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({});
      final player = ControlledNativePlayer();
      await player.create('https://fixture/video', '');
      await player.play();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoPlayerChrome(
              player: player,
              episodes: [
                Chapter(itemId: 'ep', title: 'Episode', volumeName: ''),
              ],
              currentIndex: 0,
              duration: player.duration,
              playing: true,
              onSelectEpisode: (_) async {},
              onError: (error) => throw error,
              child: const SizedBox(),
            ),
          ),
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(
          player.playWhenReady,
          isTrue,
          reason: 'Native policy decides whether confirmed PiP continues',
        );
        await player.pause();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(
          player.playWhenReady,
          isFalse,
          reason: 'Do not resume a native interruption or remote pause',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await player.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'iOS listening route detaches, advances and restores its session',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/native_player'),
        (call) async => null,
      );
      SharedPreferences.setMockInitialValues({});
      AudioPreferences.instance.resetForTest();
      final players = <ControlledNativePlayer>[];
      Widget app() => MaterialApp(
        home: ListenModePage(
          bookId: 'detached-book',
          seriesTitle: 'Fixture',
          coverUrl: '',
          episodes: [
            for (var i = 0; i < 2; i++)
              Chapter(itemId: 'ep$i', title: 'Episode $i', volumeName: ''),
          ],
          initialIndex: 0,
          resolveSource: (chapter) async =>
              EpisodeSource('https://fixture/${chapter.itemId}'),
          playerFactory: () {
            final p = ControlledNativePlayer();
            players.add(p);
            return p;
          },
        ),
      );
      try {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final session = SystemPlaybackRegistry.find('listen:detached-book');
        expect(session, isA<RetainedPlaybackSession>());
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pumpAndSettle();
        expect(players.first.disposed, isFalse);
        players.first.emitCompleted();
        await tester.pumpAndSettle();
        expect(players, hasLength(2));
        expect((session as RetainedPlaybackSession).error, isNull);
        expect(session.index, 1);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(
          SystemPlaybackRegistry.find('listen:detached-book'),
          same(session),
        );
        expect(find.text('第 2 集 · Episode 1'), findsOneWidget);
        expect(players, hasLength(2));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await SystemPlaybackRegistry.closeAll();
        await tester.pump();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('detached session advances and restores the same live player', () async {
    final first = ControlledNativePlayer();
    await first.create('https://fixture/1', '');
    await first.play();
    final players = [first];
    final saved = <int>[];
    final session = RetainedPlaybackSession(
      id: 'retained:playlist',
      player: first,
      index: 0,
      length: 2,
      loadSource: (index) async =>
          EpisodeSource('https://fixture/${index + 1}'),
      playerFactory: () {
        final p = ControlledNativePlayer();
        players.add(p);
        return p;
      },
      saveProgress: (index, player) async {
        saved.add(index);
      },
    );
    SystemPlaybackRegistry.adopt(session);
    session.detach();
    first.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restored =
        SystemPlaybackRegistry.find(session.id) as RetainedPlaybackSession;
    restored.attach();
    expect(restored, same(session));
    expect(restored.index, 1);
    expect(restored.player, same(players.last));
    expect(restored.player.playWhenReady, isTrue);
    expect(first.disposed, isTrue);
    expect(saved, contains(0));
    await Future.wait([
      SystemPlaybackRegistry.release(session.id),
      SystemPlaybackRegistry.release(session.id),
    ]);
    expect(players.last.calls.where((c) => c == 'dispose'), hasLength(1));
  });

  test('detaching a presentation preserves the same adopted session', () async {
    final session = _Session('video:detach');
    SystemPlaybackRegistry.adopt(session);
    // A page drops its reference. Only explicit release closes the business owner.
    expect(SystemPlaybackRegistry.find(session.id), same(session));
    expect(session.closes, 0);
    await SystemPlaybackRegistry.find(session.id)!.handleCommand('next');
    expect(session.commands, ['next']);
    await SystemPlaybackRegistry.release(session.id);
    expect(session.closes, 1);
    expect(SystemPlaybackRegistry.find(session.id), isNull);
  });

  test('concurrent stop releases a session exactly once', () async {
    final session = _Session('video:stop')..closing = Completer<void>();
    SystemPlaybackRegistry.adopt(session);
    final first = SystemPlaybackRegistry.release(session.id);
    final second = SystemPlaybackRegistry.release(session.id);
    expect(session.closes, 1);
    expect(SystemPlaybackRegistry.find(session.id), isNull);
    session.closing!.complete();
    await Future.wait([first, second]);
    await SystemPlaybackRegistry.release(session.id);
    expect(session.closes, 1);
  });

  test('adopt cannot silently replace an existing live session', () async {
    final first = _Session('audio:book');
    SystemPlaybackRegistry.adopt(first);
    SystemPlaybackRegistry.adopt(first);
    expect(
      () => SystemPlaybackRegistry.adopt(_Session(first.id)),
      throwsStateError,
    );
    expect(SystemPlaybackRegistry.find(first.id), same(first));
    await SystemPlaybackRegistry.release(first.id);
  });
}
