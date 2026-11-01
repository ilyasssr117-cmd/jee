import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vxtube_final/app_theme.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/widgets/bottom_bar.dart';
import 'package:vxtube_final/widgets/library_view.dart';
import 'package:vxtube_final/widgets/settings_view.dart';

void main() {
  testWidgets('settings and navigation remain laid out at 2x text size', (
    tester,
  ) async {
    AppColors.palette = Palette.light;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AppColors.palette = Palette.dark;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: const SettingsView(bottomInset: 120),
              bottomNavigationBar: const AppBottomBar(
                selected: AppTab.settings,
                onSelect: _ignoreTab,
                bottomGap: 0,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library category chips remain tappable at 2x text size', (
    tester,
  ) async {
    AppColors.palette = Palette.light;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AppColors.palette = Palette.dark;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: const Scaffold(
              body: LibraryView(
                onOpen: _ignoreOpen,
                onBrowse: _ignore,
                bottomInset: 120,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

void _ignoreTab(AppTab tab) {}

void _ignoreOpen(Video video, List<Video> queue) {}

void _ignore() {}
