import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Relative import so the test works whatever the package is called in
// pubspec.yaml (replace it with package:<your_package>/... if you prefer).
import '../lib/app_theme.dart';
import '../lib/home_page.dart';
import '../lib/local_store.dart';
import '../lib/main.dart';

void main() {
  test('iOS uses the native Cupertino page transition', () {
    final builders = buildAppTheme().pageTransitionsTheme.builders;
    expect(
      builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(builders[TargetPlatform.android], isA<TvPageTransitionsBuilder>());
  });

  testWidgets('TvTubeApp starts on the home page', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();

    await tester.pumpWidget(const TvTubeApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);

    // The test environment blocks real HTTP (every request answers 400), so
    // the first page load fails. Let that finish in real time, then render
    // the resulting state instead of leaving the load pending.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(HomePage), findsOneWidget);
  });
}
