import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fqapp/services/backend_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/system_playback_session.dart';
import 'package:fqapp/services/episode_source_cache.dart';

// Device-only G1 entry point. Supply self-owned fixtures as JSON via a local
// --dart-define-from-file file, never real media URLs/keys in committed fixtures.
// FQAPP_IOS_FIXTURES: [{name, source (HTTPS or sandbox file), keyHex}].
// This automated portion covers real AVPlayer creation, 50 seeks, 20 episode
// changes and explicit release. PiP/background transitions and the 30-minute
// endurance run must also be recorded on the physical device; this test never
// labels a simulator run as physical acceptance.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'iOS self-owned media seek and retained episode lifecycle',
    (tester) async {
      expect(Platform.isIOS, isTrue, reason: 'Run the G1 entry point on iOS');
      const input = String.fromEnvironment('FQAPP_IOS_FIXTURES');
      expect(
        input,
        isNotEmpty,
        reason: 'Provide local self-owned fixture configuration',
      );
      final fixtures = (jsonDecode(input) as List).cast<Map<String, dynamic>>();
      expect(
        fixtures.length,
        greaterThanOrEqualTo(3),
        reason: 'Include plaintext, CENC and offline fixtures',
      );
      await BackendService.instance.start();
      addTearDown(BackendService.instance.stop);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('G1 playback fixture'))),
      );
      for (final fixture in fixtures) {
        var source = fixture['source'] as String?;
        if (fixture['bytesBase64'] case final String encoded) {
          final support = await getApplicationSupportDirectory();
          final file = File(
            '${support.path}/g1-fixture-${fixtures.indexOf(fixture)}.mp4',
          );
          await file.writeAsBytes(base64Decode(encoded), flush: true);
          addTearDown(() async {
            if (await file.exists()) await file.delete();
          });
          source = file.uri.toString();
        }
        expect(source, isNotNull);
        final fixtureSource = source!;
        final player = NativePlayer();
        await player.create(fixtureSource, fixture['keyHex'] as String? ?? '');
        final errors = <Object>[];
        final observation = player.errorStream.listen(errors.add);
        final session = RetainedPlaybackSession(
          id: 'g1:${fixture['name']}',
          player: player,
          index: 0,
          length: 21,
          loadSource: (_) async =>
              EpisodeSource(fixtureSource, fixture['keyHex'] as String? ?? ''),
          playerFactory: NativePlayer.new,
          saveProgress: (_, _) async {},
        );
        SystemPlaybackRegistry.adopt(session);
        session.detach();
        try {
          await player.play();
          for (var seek = 0; seek < 50; seek++) {
            if (player.duration == Duration.zero) {
              await player.durationStream
                  .firstWhere((value) => value > Duration.zero)
                  .timeout(const Duration(seconds: 30));
            }
            final duration = player.duration.inMilliseconds;
            expect(duration, greaterThan(0));
            await player.seek(
              Duration(milliseconds: ((seek * 7919) % duration)),
            );
          }
          for (var episode = 1; episode <= 20; episode++) {
            await session.select(episode);
            expect(session.error, isNull);
            expect(session.index, episode);
          }
          expect(SystemPlaybackRegistry.find(session.id), same(session));
          expect(errors, isEmpty);
        } finally {
          await SystemPlaybackRegistry.release(session.id);
          await observation.cancel();
        }
        expect(SystemPlaybackRegistry.find(session.id), isNull);
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
