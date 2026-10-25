import 'package:flutter/material.dart';

import 'local_store.dart';

/// Small, local-only settings shared by the app shell and settings screen.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();
  static const String _themeKey = 'appearance_v1';
  static const String _hapticsKey = 'haptics_v1';

  ThemeMode _themeMode = ThemeMode.dark;
  bool _hapticsEnabled = true;

  ThemeMode get themeMode => _themeMode;
  bool get hapticsEnabled => _hapticsEnabled;
  bool get isDark => _themeMode != ThemeMode.light;

  void load() {
    final theme = LocalStore.readList(_themeKey);
    _themeMode = theme.isNotEmpty && theme.first == 'light'
        ? ThemeMode.light
        : ThemeMode.dark;
    final haptics = LocalStore.readList(_hapticsKey);
    _hapticsEnabled = haptics.isEmpty || haptics.first != 'off';
  }

  void setThemeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    LocalStore.writeList(_themeKey, <String>[
      value == ThemeMode.light ? 'light' : 'dark',
    ]);
    notifyListeners();
  }

  void setHapticsEnabled(bool value) {
    if (value == _hapticsEnabled) return;
    _hapticsEnabled = value;
    LocalStore.writeList(_hapticsKey, <String>[value ? 'on' : 'off']);
    notifyListeners();
  }
}
