import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watch_tube/home_page.dart';
import 'package:watch_tube/local_store.dart';
import 'package:watch_tube/main.dart';

void main() {
  testWidgets(
    'app starts, shows HomePage, and configures page transitions',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LocalStore.init();

      await tester.pumpWidget(const FlowApp());
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(HomePage), findsOneWidget);

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final builders = app.theme!.pageTransitionsTheme.builders;
      expect(
        builders[TargetPlatform.iOS],
        isA<CupertinoPageTransitionsBuilder>(),
      );
      expect(builders[TargetPlatform.android], isNotNull);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );
}
