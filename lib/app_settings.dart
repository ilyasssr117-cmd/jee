import 'package:flutter/foundation.dart';

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
  static const String _qualityKey = 'settings_quality_v1';

  AppThemeMode _themeMode = AppThemeMode.system;
  bool _haptics = true;
  bool _autoplayNext = true;
  bool _previewSound = true;
  int _preferredQuality = 0;

  AppThemeMode get themeMode => _themeMode;
  bool get haptics => _haptics;
  bool get autoplayNext => _autoplayNext;
  bool get previewSound => _previewSound;

  int get preferredQuality => _preferredQuality;

  void load() {
    final saved = LocalStore.readString(_themeKey);
    _themeMode = AppThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => AppThemeMode.system,
    );
    _haptics = LocalStore.readBool(_hapticsKey, fallback: true);
    _autoplayNext = LocalStore.readBool(_autoplayKey, fallback: true);
    _previewSound = LocalStore.readBool(_soundKey, fallback: true);
    final quality = int.tryParse(LocalStore.readString(_qualityKey) ?? '');
    _preferredQuality = quality != null && quality > 0 ? quality : 0;
    Haptics.enabled = _haptics;
  }

  void setPreferredQuality(int height) {
    final value = height > 0 ? height : 0;
    if (_preferredQuality == value) return;
    _preferredQuality = value;
    LocalStore.writeString(_qualityKey, '$value');
    notifyListeners();
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
}
