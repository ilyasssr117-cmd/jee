import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vxtube_final/home_page.dart';
import 'package:vxtube_final/local_store.dart';
import 'package:vxtube_final/main.dart';

void main() {
  testWidgets('app starts, shows HomePage, and configures page transitions', (
    tester,
  ) async {
    // The app now opens behind the AgeGate (audit fix 06): seed a
    // confirmed 18+ answer so this test exercises the post-gate app,
    // which is what its assertions describe.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'age_asked': true,
      'is18': true,
    });
    await LocalStore.init();

    await tester.pumpWidget(const VXTUBEFinalApp());
    await tester.pump();
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
  });
}
