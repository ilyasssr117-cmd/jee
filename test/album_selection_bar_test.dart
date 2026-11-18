import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/album_page.dart';
import 'package:vxtube_final/widgets/app_button.dart';
import 'package:vxtube_final/touch.dart';

void main() {
  testWidgets(
    'selection footer exposes Cancel beside Select all',
    (tester) async {
    final previousHaptics = Haptics.enabled;
    Haptics.enabled = false;
    addTearDown(() => Haptics.enabled = previousHaptics);
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionBarFrame(
            count: 24,
            onSelectAll: () {},
            onCancel: () => cancelled = true,
            actions: [
              Expanded(
                child: AppButton(
                  label: 'Download',
                  icon: Icons.download_rounded,
                  expand: true,
                  singleLine: true,
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('24 selected'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    final download = tester.widget<Text>(find.text('Download'));
    expect(download.maxLines, 1);
    expect(download.softWrap, isFalse);

    await tester.tap(find.text('Cancel'));
      expect(cancelled, isTrue);
    },
  );
}

