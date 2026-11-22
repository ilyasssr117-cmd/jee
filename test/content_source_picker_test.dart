import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/content_source.dart';
import 'package:vxtube_final/widgets/content_source_picker.dart';

void main() {
  testWidgets('content source picker supports remote option selection',
      (tester) async {
    ContentSource? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showContentSourcePicker(
                      context,
                      initialSource: ContentSource.fetish,
                    );
                  },
                  child: const Text('Open picker'),
                ),
              )),
    ));

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'Content source option');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(result, ContentSource.straight);
    expect(tester.takeException(), isNull);
  });
}
