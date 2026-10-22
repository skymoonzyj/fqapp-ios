import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/platform_capabilities.dart';

void main() {
  testWidgets(
    'iOS settings omit unsupported PiP, decoder and e-ink controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('fqapp/native_player');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => false,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('短剧'));
      await tester.pumpAndSettle();
      expect(find.text('切后台悬浮窗播放'), findsNothing);
      expect(find.text('画中画播放'), findsNothing);
      expect(find.text('视频解码器'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.text('墨水屏模式'), findsNothing);
      expect(find.text('深色模式'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'supported iOS PiP uses system wording without overlay permission',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final methods = <String>[];
      const channel = MethodChannel('fqapp/native_player');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        methods.add(call.method);
        return true;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('短剧'));
      await tester.pumpAndSettle();
      expect(find.text('画中画播放'), findsOneWidget);
      expect(find.textContaining('悬浮窗权限'), findsNothing);
      await tester.tap(find.text('画中画播放'));
      await tester.pumpAndSettle();
      expect(methods, contains('canDrawOverlays'));
      expect(methods, isNot(contains('requestOverlayPermission')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test(
    'iOS exposes only available controls and requires a PiP runtime result',
    () {
      final unsupported = PlatformCapabilities.forPlatform(TargetPlatform.iOS);
      expect(unsupported.reader, isTrue);
      expect(unsupported.speech, isTrue);
      expect(unsupported.overlayPermission, isFalse);
      expect(unsupported.decoderPreference, isFalse);
      expect(unsupported.eink, isFalse);
      expect(unsupported.volumePaging, isFalse);
      expect(unsupported.pictureInPicture, isFalse);
      expect(
        PlatformCapabilities.forPlatform(
          TargetPlatform.iOS,
          pictureInPictureSupported: true,
        ).pictureInPicture,
        isTrue,
      );
    },
  );

  test(
    'Android settings remain available and Windows has no mobile controls',
    () {
      final android = PlatformCapabilities.forPlatform(TargetPlatform.android);
      expect(android.overlayPermission, isTrue);
      expect(android.decoderPreference, isTrue);
      expect(android.eink, isTrue);
      expect(android.volumePaging, isTrue);
      final windows = PlatformCapabilities.forPlatform(TargetPlatform.windows);
      expect(windows.reader, isTrue);
      expect(windows.speech, isTrue);
      expect(windows.overlayPermission, isFalse);
      expect(windows.decoderPreference, isFalse);
      expect(windows.volumePaging, isFalse);
      expect(windows.pictureInPicture, isFalse);
    },
  );
}
