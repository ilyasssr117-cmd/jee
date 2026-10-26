import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper around [SharedPreferences].
///
/// [init] runs once at start-up; after that every read is synchronous, so the
/// stores below never need to be awaited from widgets. If storage is not
/// available the app simply keeps everything in memory.
abstract final class LocalStore {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('[STORE] SharedPreferences unavailable: $error');
    }
  }

  static List<String> readList(String key) {
    try {
      return _prefs?.getStringList(key) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  static void writeList(String key, List<String> value) {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setStringList(key, value).then((_) {}, onError: (Object error) {
        debugPrint('[STORE] Could not save $key: $error');
      }),
    );
  }

  static String? readString(String key) {
    try {
      return _prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }

  static void writeString(String key, String value) {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setString(key, value).then((_) {}, onError: (Object error) {
        debugPrint('[STORE] Could not save $key: $error');
      }),
    );
  }

  static bool readBool(String key, {required bool fallback}) {
    try {
      return _prefs?.getBool(key) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  static void writeBool(String key, bool value) {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setBool(key, value).then((_) {}, onError: (Object error) {
        debugPrint('[STORE] Could not save $key: $error');
      }),
    );
  }
}
