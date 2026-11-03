import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vxtube_final/widgets/expandable_text.dart';

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

int? _maxLines(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).maxLines;

void main() {
  testWidgets('short title is plain text with no toggle words', (tester) async {
    await tester.pumpWidget(_host('Short'));
    expect(find.text('more'), findsNothing);
    expect(find.text('less'), findsNothing);
    expect(_maxLines(tester), isNull);
  });

  testWidgets('long title has no "more" word and toggles on tap', (
    tester,
  ) async {
    await tester.pumpWidget(_host('A very long title ' * 12));
    expect(find.text('more'), findsNothing);
    expect(_maxLines(tester), 2);

    await tester.tap(find.byType(Text));
    await tester.pumpAndSettle();
    expect(find.text('less'), findsNothing);
    expect(_maxLines(tester), isNull);

    await tester.tap(find.byType(Text));
    await tester.pumpAndSettle();
    expect(_maxLines(tester), 2);
  });
}
