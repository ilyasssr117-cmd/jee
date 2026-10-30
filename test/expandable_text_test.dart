import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watch_tube/widgets/expandable_text.dart';

Widget _host(String text) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: ExpandableText(
              text,
              collapsedLines: 2,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('short title shows no more/less toggle', (tester) async {
    await tester.pumpWidget(_host('Short'));
    expect(find.text('more'), findsNothing);
    expect(find.text('less'), findsNothing);
  });

  testWidgets('long title toggles between more and less', (tester) async {
    await tester.pumpWidget(_host('A very long title ' * 12));
    expect(find.text('more'), findsOneWidget);

    await tester.tap(find.text('more'));
    await tester.pumpAndSettle();
    expect(find.text('less'), findsOneWidget);
    expect(find.text('more'), findsNothing);

    await tester.tap(find.text('less'));
    await tester.pumpAndSettle();
    expect(find.text('more'), findsOneWidget);
  });
}
