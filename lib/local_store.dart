import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class LocalStore {
  static SharedPreferences? _prefs;
  static Future<void> _writeQueue = Future<void>.value();
  // SharedPreferences writes are asynchronous. Keep a small optimistic
  // in-memory view so reads made immediately after a write see the new value.
  static final Map<String, String> _stringOverlay = <String, String>{};
  static final Map<String, List<String>> _listOverlay =
      <String, List<String>>{};
  static final Map<String, bool> _boolOverlay = <String, bool>{};

  static Future<void> init() async {
    try {
      await _writeQueue.catchError((Object _) {});
      _prefs = await SharedPreferences.getInstance();
      _stringOverlay.clear();
      _listOverlay.clear();
      _boolOverlay.clear();
    } catch (error) {
      debugPrint('[STORE] SharedPreferences unavailable: ${error.runtimeType}');
    }
  }

  static List<String> readList(String key) {
    try {
      final overlay = _listOverlay[key];
      if (overlay != null) return List<String>.unmodifiable(overlay);
      return _prefs?.getStringList(key) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  static void writeList(String key, List<String> value) {
    final snapshot = List<String>.unmodifiable(value);
    _listOverlay[key] = snapshot;
    unawaited(writeListAsync(key, snapshot));
  }

  static Future<void> writeListAsync(String key, List<String> value) {
    final snapshot = List<String>.unmodifiable(value);
    _listOverlay[key] = snapshot;
    return _enqueueWrite(() async {
      await _prefs!.setStringList(key, snapshot);
    }, key);
  }

  static String? readString(String key) {
    try {
      if (_stringOverlay.containsKey(key)) return _stringOverlay[key];
      return _prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }

  static void writeString(String key, String value) {
    _stringOverlay[key] = value;
    unawaited(writeStringAsync(key, value));
  }

  static Future<void> writeStringAsync(String key, String value) {
    _stringOverlay[key] = value;
    return _enqueueWrite(() async {
      await _prefs!.setString(key, value);
    }, key);
  }

  static bool readBool(String key, {required bool fallback}) {
    try {
      return _boolOverlay[key] ?? _prefs?.getBool(key) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  static void writeBool(String key, bool value) {
    _boolOverlay[key] = value;
    unawaited(
      _enqueueWrite(() async {
        await _prefs!.setBool(key, value);
      }, key),
    );
  }

  static Future<void> flush() => _writeQueue.catchError((Object _) {});

  static Future<void> _enqueueWrite(
    Future<void> Function() operation,
    String key,
  ) {
    if (_prefs == null) return Future<void>.value();
    final queued = _writeQueue.catchError((Object _) {}).then((_) async {
      try {
        if (_prefs == null) return;
        await operation();
      } catch (error) {
        debugPrint('[STORE] Could not save $key: ${error.runtimeType}');
      }
    });
    _writeQueue = queued;
    return queued;
  }
}

Future<void> purgeStaleTempFiles() async {
  try {
    final dir = await getTemporaryDirectory();
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('reel_') || !name.endsWith('.mp4')) continue;
      if ((await entity.lastModified()).isBefore(cutoff)) {
        await entity.delete();
      }
    }
  } catch (_) {}
}
