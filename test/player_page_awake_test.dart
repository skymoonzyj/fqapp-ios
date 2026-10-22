import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

void main() {
  testWidgets(
    'page awake ID survives episode replacement and overlapping navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <Map<dynamic, dynamic>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('fqapp/native_player');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setKeepScreenOn') calls.add(call.arguments as Map);
        return null;
      });
      await tester.binding.setSurfaceSize(const Size(400, 800));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      final players = <ControlledNativePlayer>[];
      Widget page(String book) => PlayerPage(
        bookId: book,
        title: book,
        eps: [
          for (final id in ['1', '2'])
            Chapter(itemId: id, title: id, volumeName: ''),
        ],
        startIndex: 0,
        historyStore: ControlledReaderStore(),
        contentLoader: (chapter) async => {
          'video_url': 'https://example.invalid/${chapter.itemId}.mp4',
        },
        playerFactory: () {
          final player = ControlledNativePlayer();
          players.add(player);
          return player;
        },
      );
      try {
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: page('A')),
        );
        await _flush(tester);
        expect(calls, hasLength(1));
        final a = calls.single['ownerID'];
        expect(
          a,
          isA<String>().having((s) => s.isNotEmpty, 'nonempty', isTrue),
        );
        final chrome = tester.widget<VideoPlayerChrome>(
          find.byType(VideoPlayerChrome),
        );
        unawaited(chrome.onSelectEpisode(1));
        await _flush(tester);
        expect(players, hasLength(2));
        expect(
          calls,
          hasLength(1),
          reason: 'Player replacement retains page ownership',
        );
        unawaited(
          navigator.currentState!.pushReplacement(
            MaterialPageRoute<void>(builder: (_) => page('B')),
          ),
        );
        await tester.pump();
        await _flush(tester);
        expect(
          calls,
          hasLength(2),
          reason: 'Both pages overlap during transition',
        );
        final b = calls.last['ownerID'];
        expect(
          b,
          isA<String>().having((s) => s.isNotEmpty, 'nonempty', isTrue),
        );
        expect(b, isNot(a));
        await tester.pump(const Duration(seconds: 1));
        await _flush(tester);
        expect(calls, [
          {'on': true, 'ownerID': a},
          {'on': true, 'ownerID': b},
          {'on': false, 'ownerID': a},
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        expect(calls.last, {'on': false, 'ownerID': b});
        expect(calls, hasLength(4));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester);
        await tester.binding.setSurfaceSize(null);
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}
