import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
