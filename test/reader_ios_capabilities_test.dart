import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';

void main() {
  testWidgets(
    'iOS reader hides hardware volume paging and eink controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderAppearanceSheet(
              initialValue: const ReaderPreferences(),
              onChanged: (_) {},
              onPickFont: () async => null,
            ),
          ),
        ),
      );
      expect(find.text('音量键翻页', skipOffstage: false), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '墨水屏阅读背景',
        ),
        findsNothing,
      );
      expect(find.text('背景'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets(
    'Android reader keeps hardware volume paging and eink controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderAppearanceSheet(
              initialValue: const ReaderPreferences(),
              onChanged: (_) {},
              onPickFont: () async => null,
            ),
          ),
        ),
      );
      expect(find.text('音量键翻页', skipOffstage: false), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '墨水屏阅读背景',
        ),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
