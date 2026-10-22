import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/widgets/audio/system_tts_controls.dart';

import 'support/controlled_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _methods = MethodChannel('fqapp/system_tts');
const _eventMethods = MethodChannel('fqapp/system_tts_events');
const _playerMethods = MethodChannel('fqapp/native_player');
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Completer<int>? initialization;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    calls = [];
    initialization = null;
    messenger.setMockMethodCallHandler(_eventMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_playerMethods, (_) async => null);
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return initialization?.future ?? 4000;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_eventMethods, null);
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_playerMethods, null);
  });

  List<MethodCall> spoken() => calls.where((c) => c.method == 'speak').toList();
  Future<void> event(Map<String, Object?> data) =>
      messenger.handlePlatformMessage(
        _eventMethods.name,
        _codec.encodeSuccessEnvelope(data),
        (_) {},
      );

  Future<void> remote(String action) => messenger.handlePlatformMessage(
    _playerMethods.name,
    _codec.encodeMethodCall(
      MethodCall('onNotificationAction', {'action': action}),
    ),
    (_) {},
  );

  SystemTtsPlayback session({
    String text = '正文。',
    Future<String> Function(Chapter)? loader,
    VoidCallback? onStop,
  }) => SystemTtsPlayback(
    SystemTtsBook(
      bookId: 'local:book',
      title: '本地书',
      chapters: [
        Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
        Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
      ],
      startIndex: 0,
      localOnly: true,
      initialContent: ChapterContent.fromPlainText(text),
      textLoader: loader,
    ),
    beforePlay: () async {},
    onStop: onStop ?? () {},
  );

  testWidgets(
    'remote explicit pause and play are idempotent and retain position',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session(text: '甲乙丙丁。');
      try {
        playback.start();
        await tester.pump();
        final id = (spoken().single.arguments as Map)['id'];
        await event({'type': 'range', 'id': id, 'start': 2});
        await remote('pause');
        await tester.pump();
        expect(playback.wantPlay, isFalse);
        final stops = calls.where((c) => c.method == 'stop').length;
        expect(stops, 2); // Chapter start plus explicit pause.
        await remote('pause');
        await tester.pump();
        expect(calls.where((c) => c.method == 'stop'), hasLength(stops));
        await remote('play');
        await tester.pump();
        expect(playback.wantPlay, isTrue);
        expect((spoken().last.arguments as Map)['text'], '丙丁。');
        expect(spoken(), hasLength(2));
        await remote('play');
        await tester.pump();
        expect(playback.wantPlay, isTrue);
        expect(spoken(), hasLength(2));
      } finally {
        await playback.close();
        await remote('play');
        await remote('pause');
        await tester.pump();
      }
      expect(playback.wantPlay, isFalse);
      expect(spoken(), hasLength(2));
    },
  );

  testWidgets('remote pause invalidates pending initialization', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    initialization = Completer<int>();
    final playback = session();
    try {
      playback.start();
      await tester.pump();
      expect(calls.any((c) => c.method == 'initialize'), isTrue);
      await remote('pause');
      await tester.pump();
      initialization!.complete(4000);
      await tester.pump();
      expect(playback.wantPlay, isFalse);
      expect(playback.loading, isFalse);
      expect(spoken(), isEmpty);
    } finally {
      if (!initialization!.isCompleted) initialization!.complete(4000);
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets('remote pause cancels pending chapter and play reloads it', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final pending = Completer<String>();
    var loads = 0;
    final playback = session(
      loader: (_) => ++loads == 1 ? pending.future : Future.value('新正文。'),
    );
    try {
      playback.start();
      await tester.pump();
      await remote('next');
      await tester.pump();
      expect(playback.loading, isTrue);
      await remote('pause');
      await tester.pump();
      pending.complete('过期正文。');
      await tester.pump();
      expect(playback.wantPlay, isFalse);
      expect(spoken(), hasLength(1));
      await remote('play');
      await tester.pump();
      expect(loads, 2);
      expect((spoken().last.arguments as Map)['text'], '新正文。');
    } finally {
      if (!pending.isCompleted) pending.complete('过期正文。');
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets(
    'replaced speech owner cannot speak late or clear successor remote handler',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      initialization = Completer<int>();
      final old = session(text: '旧朗读。');
      final successor = session(text: '新朗读。');
      try {
        old.start();
        await tester.pump();
        expect(calls.any((c) => c.method == 'initialize'), isTrue);
        successor.start();
        await tester.pump();
        await remote('pause');
        await tester.pump();
        initialization!.complete(4000);
        await tester.pump();
        expect(spoken(), isEmpty);
        final shutdowns = calls.where((c) => c.method == 'shutdown').length;
        await old.close();
        expect(ListeningSession.instance.bookId, successor.book.bookId);
        await remote('play');
        await tester.pump();
        expect(spoken(), hasLength(1));
        expect((spoken().single.arguments as Map)['text'], '新朗读。');
        expect(successor.wantPlay, isTrue);
        await remote('pause');
        await tester.pump();
        expect(successor.wantPlay, isFalse);
        expect(
          calls.where((c) => c.method == 'shutdown'),
          hasLength(shutdowns),
        );
        // A superseded session cannot be restarted even through a stale UI.
        await old.resume();
        expect(spoken(), hasLength(1));
      } finally {
        if (!initialization!.isCompleted) initialization!.complete(4000);
        await old.close();
        await successor.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'video takeover still permits scope pause and deliberate UI speech resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session();
      void video(String action) {}
      try {
        playback.start();
        await tester.pump();
        NativePlayer.setRemoteCommandHandler(onAction: video);
        // AudioPlaybackScope calls pause after the video bound its own handler.
        await playback.pause();
        expect(playback.wantPlay, isFalse);
        expect(calls.where((call) => call.method == 'stop'), hasLength(2));
        await playback
            .resume(); // Explicit UI intent, rather than a late remote action.
        await tester.pump();
        expect(playback.wantPlay, isTrue);
        expect(spoken(), hasLength(2));
        await remote('pause');
        await tester.pump();
        expect(playback.wantPlay, isFalse);
        NativePlayer.setRemoteCommandHandler(onAction: video);
        await playback.close();
        expect(ListeningSession.instance.bookId, isNull);
        expect(NativePlayer.ownsRemoteCommandHandler(video), isTrue);
      } finally {
        await playback.close();
        NativePlayer.clearRemoteCommandHandler(owner: video);
        await tester.pump();
      }
    },
  );

  testWidgets(
    'real audio scope pauses speech after video takeover and switches speech sessions',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      final fixture = session();
      final next = session(text: '下一本。');
      final video = ControlledNativePlayer();
      void videoAction(String action) {}
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            builder: (_, child) =>
                AudioPlaybackScope(navigatorKey: navigator, child: child!),
            home: const Scaffold(body: Text('scope-host')),
          ),
        );
        final context = tester.element(find.text('scope-host'));
        await AudioPlaybackScope.startSystemTts(context, fixture.book);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final old = tester
            .widget<SystemTtsMiniBar>(find.byType(SystemTtsMiniBar))
            .session;
        expect(old.wantPlay, isTrue);
        NativePlayer.setRemoteCommandHandler(onAction: videoAction);
        await NativePlayer.beforePlay!(video);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(old.wantPlay, isFalse);
        expect(ListeningSession.instance.playing, isFalse);
        expect(calls.where((c) => c.method == 'stop'), hasLength(2));
        await old.resume();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(spoken(), hasLength(2));
        await AudioPlaybackScope.startSystemTts(context, next.book);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(old.closed, isTrue);
        expect((spoken().last.arguments as Map)['text'], '下一本。');
        await remote('pause');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final active = tester
            .widget<SystemTtsMiniBar>(find.byType(SystemTtsMiniBar))
            .session;
        expect(active.wantPlay, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await video.dispose();
        fixture.dispose();
        next.dispose();
        NativePlayer.clearRemoteCommandHandler(owner: videoAction);
      }
    },
  );

  testWidgets('remote toggle previous next and stop retain speech semantics', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var stops = 0;
    final playback = session(
      loader: (_) async => '第二章正文。',
      onStop: () => stops++,
    );
    try {
      playback.start();
      await tester.pump();
      await remote('next');
      await tester.pump();
      expect(playback.index, 1);
      expect((spoken().last.arguments as Map)['text'], '第二章正文。');
      await remote('prev');
      await tester.pump();
      expect(playback.index, 0);
      expect((spoken().last.arguments as Map)['text'], '正文。');
      await remote('playPause');
      await tester.pump();
      expect(playback.wantPlay, isFalse);
      await remote('playPause');
      await tester.pump();
      expect(playback.wantPlay, isTrue);
      await remote('stop');
      expect(stops, 1);
    } finally {
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets(
    'iOS settings offer system voices without Android engine guidance',
    (tester) async {
      messenger.setMockMethodCallHandler(_methods, (call) async {
        if (call.method == 'engines') {
          return {
            'engines': [
              {'package': 'ios:zh-test', 'label': '中文语音'},
            ],
            'defaultEngine': 'ios:zh-test',
          };
        }
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: SystemTtsSettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('朗读音色'), findsOneWidget);
      expect(find.textContaining('MultiTTS'), findsNothing);
      expect(find.textContaining('辅助功能'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文语音').last);
      await tester.pumpAndSettle();
      expect((await SystemTtsPreferences.load()).engine, 'ios:zh-test');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('pause invalidates a pending engine initialization', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    initialization = Completer<int>();
    final playback = session();
    try {
      playback.start();
      await tester.pump();
      expect(calls.any((c) => c.method == 'initialize'), isTrue);
      await playback.pause();
      initialization!.complete(4000);
      await tester.pump();
      expect(spoken(), isEmpty);
      expect(playback.wantPlay, isFalse);
    } finally {
      if (!initialization!.isCompleted) initialization!.complete(4000);
      await playback.close();
      await tester.pump();
    }
  });

  testWidgets(
    'closing during next local chapter load rejects its late result',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final chapter = Completer<String>();
      final requested = <String>[];
      final playback = session(
        loader: (c) {
          requested.add(c.itemId);
          return chapter.future;
        },
      );
      try {
        playback.start();
        await tester.pump();
        final id = (spoken().single.arguments as Map)['id'];
        await event({'type': 'done', 'id': id});
        await tester.pump();
        expect(requested, ['c2']);
        await playback.close();
        chapter.complete('迟到的第二章');
        await tester.pump();
        expect(spoken(), hasLength(1));
        expect(ListeningSession.instance.bookId, isNull);
      } finally {
        if (!chapter.isCompleted) chapter.complete('第二章');
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'resume uses the reported range and ignores an old done callback',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session(text: '甲乙丙丁。');
      try {
        playback.start();
        await tester.pump();
        final oldId = (spoken().single.arguments as Map)['id'];
        await event({'type': 'range', 'id': oldId, 'start': 2});
        await playback.pause();
        await playback.resume();
        expect((spoken().last.arguments as Map)['text'], '丙丁。');
        await event({'type': 'done', 'id': oldId});
        await tester.pump();
        expect(playback.index, 0);
        expect(spoken(), hasLength(2));
        expect(ListeningSession.instance.duration, Duration.zero);
        expect(ListeningSession.instance.textProgress, closeTo(0.4, 0.001));
      } finally {
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'chunk boundaries preserve an astral character and chapter text',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final text = '${List.filled(299, '甲').join()}😀乙';
      final playback = session(text: text);
      try {
        playback.start();
        await tester.pump();
        final first = spoken().single.arguments as Map;
        expect((first['text'] as String).length, 299);
        await event({'type': 'done', 'id': first['id']});
        await tester.pump();
        final second = spoken().last.arguments as Map;
        expect(second['text'], '😀乙');
        expect('${first['text']}${second['text']}', text);
      } finally {
        await playback.close();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'background disabled and engine interruptions cancel pending play',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final playback = session();
      try {
        playback.start();
        await tester.pump();
        await AudioPreferences.instance.setBackgroundPlayback(false);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        await remote('play');
        await tester.pump();
        expect(playback.wantPlay, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await playback.resume();
        await event({'type': 'interrupted', 'id': null});
        await tester.pump();
        expect(playback.wantPlay, isFalse);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await playback.close();
        await tester.pump();
      }
    },
  );

  test(
    'local books without a loader fail instead of falling back to an API',
    () async {
      final playback = session();
      await expectLater(playback.book.load(1), throwsStateError);
      playback.dispose();
    },
  );
}
