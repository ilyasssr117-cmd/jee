import 'dart:collection';
import 'dart:convert';

import 'local_store.dart';
import 'models.dart';
import 'video_json.dart';

/// Small persistent cache for catalogue metadata.
/// Stream URLs are intentionally not persisted because signed media URLs expire.
abstract final class OfflineListingCache {
  static const String _storageKey = 'offline_listing_pages_v1';
  static const int _maxPages = 18;
  static const int _maxKeyLength = 256;
  static const int _maxStoredBytes = 3 * 1024 * 1024;
  static const int _maxVideosPerPage = 60;
  static const Duration _maxAge = Duration(days: 7);

  static final LinkedHashMap<String, _OfflinePage> _pages =
      LinkedHashMap<String, _OfflinePage>();
  static Future<void> _writeQueue = Future<void>.value();
  static bool _persistScheduled = false;
  static bool _persistDirty = false;
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;

    final raw = LocalStore.readString(_storageKey);
    if (raw == null || raw.isEmpty || utf8.encode(raw).length > _maxStoredBytes) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final now = DateTime.now();
      for (final item in decoded) {
        if (item is! Map) continue;
        final key = item['key'];
        final savedAt = item['savedAt'];
        final rawVideos = item['videos'];
        if (key is! String ||
            key.isEmpty ||
            key.length > _maxKeyLength ||
            savedAt is! int ||
            rawVideos is! List) {
          continue;
        }
        final timestamp = DateTime.fromMillisecondsSinceEpoch(savedAt);
        if (now.difference(timestamp) > _maxAge || timestamp.isAfter(now)) {
          continue;
        }

        final videos = <Video>[];
        for (final rawVideo in rawVideos.take(_maxVideosPerPage)) {
          if (rawVideo is! Map) continue;
          final video = videoFromJson(Map<String, dynamic>.from(rawVideo));
          if (video != null) videos.add(video);
        }
        if (videos.isNotEmpty) {
          _pages[key] = _OfflinePage(
            timestamp,
            List<Video>.unmodifiable(videos),
          );
        }
      }
      _trim();
    } catch (_) {
      _pages.clear();
    }
  }

  /// Returns the latest saved page, even when stale, for immediate offline UI.
  static List<Video>? read(String key) {
    init();
    final page = _pages.remove(key);
    if (page == null) return null;
    if (DateTime.now().difference(page.savedAt) > _maxAge) {
      _schedulePersist();
      return null;
    }
    _pages[key] = page;
    return page.videos;
  }

  static void write(String key, List<Video> videos) {
    init();
    if (key.isEmpty || key.length > _maxKeyLength || videos.isEmpty) return;

    _pages.remove(key);
    _pages[key] = _OfflinePage(
      DateTime.now(),
      List<Video>.unmodifiable(videos.take(_maxVideosPerPage)),
    );
    _trim();
    _schedulePersist();
  }

  static String _encodePages() => jsonEncode(<Map<String, Object?>>[
    for (final entry in _pages.entries)
      <String, Object?>{
        'key': entry.key,
        'savedAt': entry.value.savedAt.millisecondsSinceEpoch,
        'videos': <Map<String, dynamic>>[
          for (final video in entry.value.videos) videoToJson(video),
        ],
      },
  ]);

  static void _trim() {
    while (_pages.length > _maxPages) {
      _pages.remove(_pages.keys.first);
    }
  }

  static void _schedulePersist() {
    _persistDirty = true;
    if (_persistScheduled) return;
    _persistScheduled = true;

    _writeQueue = _writeQueue
        .catchError((Object _) {})
        .then((_) async {
          // Coalesce rapid page writes into one preferences update. This avoids
          // queuing many large JSON snapshots while the user scrolls quickly.
          while (_persistDirty) {
            _persistDirty = false;
            await Future<void>.delayed(const Duration(milliseconds: 160));
            var snapshot = _encodePages();
            // Keep the persistent catalogue below a small storage budget.
            // Oldest pages are evicted first; the current page is retained.
            while (utf8.encode(snapshot).length > _maxStoredBytes &&
                _pages.length > 1) {
              _pages.remove(_pages.keys.first);
              snapshot = _encodePages();
            }
            if (utf8.encode(snapshot).length > _maxStoredBytes &&
                _pages.isNotEmpty) {
              final lastKey = _pages.keys.last;
              final page = _pages[lastKey]!;
              _pages[lastKey] = _OfflinePage(
                page.savedAt,
                List<Video>.unmodifiable(page.videos.take(12)),
              );
              snapshot = _encodePages();
            }
            if (utf8.encode(snapshot).length <= _maxStoredBytes) {
              await LocalStore.writeStringAsync(_storageKey, snapshot);
            }
          }
        })
        .whenComplete(() {
          _persistScheduled = false;
          if (_persistDirty) _schedulePersist();
        });
  }
}

class _OfflinePage {
  const _OfflinePage(this.savedAt, this.videos);

  final DateTime savedAt;
  final List<Video> videos;
}
