import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watch_tube/home_page.dart';
import 'package:watch_tube/local_store.dart';
import 'package:watch_tube/main.dart';

void main() {
  testWidgets('App starts successfully', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();

    await tester.pumpWidget(const MyApp());

    expect(find.byType(MaterialApp), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(
        const Duration(milliseconds: 300),
      ),
    );

    await tester.pump(
      const Duration(milliseconds: 300),
    );

    expect(tester.takeException(), isNull);
  });
}
