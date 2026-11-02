import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/widgets/app_button.dart';

void main() {
  testWidgets('single-line action labels stay unwrapped at narrow widths', (
    tester,
  ) async {
    for (final width in <double>[88, 108, 132]) {
      for (final scale in <double>[1, 1.5, 2]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 300),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: AppButton(
                      label: 'Download',
                      icon: Icons.download_rounded,
                      singleLine: true,
                      expand: true,
                      onPressed: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final label = tester.widget<Text>(find.text('Download'));
        expect(label.maxLines, 1);
        expect(label.softWrap, isFalse);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('required action width grows with Dynamic Type', (tester) async {
    final requiredWidths = <double>[];
    for (final scale in <double>[1, 2]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(400, 300),
              textScaler: TextScaler.linear(scale),
            ),
            child: Builder(
              builder: (context) {
                requiredWidths.add(
                  appButtonRequiredWidth(context, label: 'Download'),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }
    expect(requiredWidths.last, greaterThan(requiredWidths.first));
  });
}
