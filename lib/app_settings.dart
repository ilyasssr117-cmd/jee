import 'package:flutter/foundation.dart';

import 'content_source.dart';
import 'local_store.dart';
import 'touch.dart';

enum AppThemeMode { system, dark, light }

class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _themeKey = 'settings_theme_v1';
  static const String _hapticsKey = 'settings_haptics_v1';
  static const String _autoplayKey = 'settings_autoplay_v1';
  static const String _soundKey = 'settings_preview_sound_v1';
  static const String _contentSourceKey = 'settings_content_source_v1';
  static const String _sourceChosenKey = 'settings_content_source_chosen_v1';
  static const String _introSeenKey = 'settings_intro_seen_v1';
  static const String _analyticsKey = 'settings_analytics_enabled_v1';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _haptics = true;
  bool _autoplayNext = true;
  bool _previewSound = true;
  ContentSource _contentSource = ContentSource.fetish;
  bool _sourceChosen = false;
  bool _introSeen = false;
  bool _analyticsEnabled = true;

  AppThemeMode get themeMode => _themeMode;
  bool get haptics => _haptics;
  bool get autoplayNext => _autoplayNext;
  bool get previewSound => _previewSound;
  ContentSource get contentSource => _contentSource;

  bool get hasChosenContentSource => _sourceChosen;

  /// Full intro plays on the first launch only (fixes 21).
  bool get introSeen => _introSeen;

  /// User-facing analytics consent (fix 42). Default on, revocable in
  /// Settings; honored by AnalyticsService before any capture.
  bool get analyticsEnabled => _analyticsEnabled;

  void load() {
    final saved = LocalStore.readString(_themeKey);
    _themeMode = AppThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => AppThemeMode.system,
    );
    _haptics = LocalStore.readBool(_hapticsKey, fallback: true);
    _autoplayNext = LocalStore.readBool(_autoplayKey, fallback: true);
    _previewSound = LocalStore.readBool(_soundKey, fallback: true);
    _contentSource = ContentSource.fromStoredValue(
      LocalStore.readString(_contentSourceKey),
    );
    _sourceChosen =
        LocalStore.readBool(_sourceChosenKey, fallback: false) ||
            LocalStore.readString(_contentSourceKey) != null;
    _introSeen = LocalStore.readBool(_introSeenKey, fallback: false);
    _analyticsEnabled = LocalStore.readBool(_analyticsKey, fallback: true);
    Haptics.enabled = _haptics;
  }

  void markIntroSeen() {
    if (_introSeen) return;
    _introSeen = true;
    LocalStore.writeBool(_introSeenKey, true);
  }

  void setAnalyticsEnabled(bool value) {
    if (_analyticsEnabled == value) return;
    _analyticsEnabled = value;
    LocalStore.writeBool(_analyticsKey, value);
    notifyListeners();
  }

  void markContentSourceChosen() {
    if (_sourceChosen) return;
    _sourceChosen = true;
    LocalStore.writeBool(_sourceChosenKey, true);
  }

  void setThemeMode(AppThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    LocalStore.writeString(_themeKey, mode.name);
    notifyListeners();
  }

  void setHaptics(bool value) {
    if (_haptics == value) return;
    _haptics = value;
    Haptics.enabled = value;
    LocalStore.writeBool(_hapticsKey, value);
    notifyListeners();
  }

  void setAutoplayNext(bool value) {
    if (_autoplayNext == value) return;
    _autoplayNext = value;
    LocalStore.writeBool(_autoplayKey, value);
    notifyListeners();
  }

  void setPreviewSound(bool value) {
    if (_previewSound == value) return;
    _previewSound = value;
    LocalStore.writeBool(_soundKey, value);
    notifyListeners();
  }

  void setContentSource(ContentSource source) {
    markContentSourceChosen();
    if (_contentSource == source) return;
    _contentSource = source;
    LocalStore.writeString(_contentSourceKey, source.name);
    notifyListeners();
  }
}
