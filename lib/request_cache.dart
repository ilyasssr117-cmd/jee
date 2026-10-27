import 'dart:collection';

import 'models.dart';

/// Small in-memory cache with a time limit. Also shares one running request
/// between callers that ask for the same key at the same time, so the app
/// never sends the same request twice.
class TtlCache<V> {
  TtlCache({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 40,
    this.cacheable,
  });

  /// Results for which this returns false are handed to the caller but not
  /// kept (an empty page caused by a hiccup must not stick for minutes).
  final bool Function(V value)? cacheable;

  final Duration ttl;
  final int maxEntries;

  final LinkedHashMap<String, _Entry<V>> _entries =
      LinkedHashMap<String, _Entry<V>>();
  final Map<String, Future<V>> _running = <String, Future<V>>{};

  /// Returns the cached value for [key] while it is fresh; otherwise runs
  /// [loader]. [force] skips the cache (pull-to-refresh).
  Future<V> fetch(
    String key,
    Future<V> Function() loader, {
    bool force = false,
  }) {
    if (!force) {
      final hit = _entries[key];
      if (hit != null && DateTime.now().isBefore(hit.expires)) {
        _entries.remove(key); // Mark as recently used.
        _entries[key] = hit;
        return Future<V>.value(hit.value);
      }
      final running = _running[key];
      if (running != null) return running;
    }

    final future = loader().then((value) {
      if (cacheable == null || cacheable!(value)) {
        _entries.remove(key);
        _entries[key] = _Entry<V>(value, DateTime.now().add(ttl));
        while (_entries.length > maxEntries) {
          _entries.remove(_entries.keys.first);
        }
      }
      return value;
    });
    final tracked = future.whenComplete(() => _running.remove(key));
    _running[key] = tracked;
    return tracked;
  }

  void clear() => _entries.clear();
}

class _Entry<V> {
  const _Entry(this.value, this.expires);

  final V value;
  final DateTime expires;
}

/// Lists of videos by "category|page" and "query|page".
final TtlCache<List<Video>> listingCache =
    TtlCache<List<Video>>(
  ttl: const Duration(minutes: 4),
  maxEntries: 60,
  cacheable: (videos) => videos.isNotEmpty,
);

/// "More like this" lists by video id.
final TtlCache<List<Video>> relatedCache =
    TtlCache<List<Video>>(
  ttl: const Duration(minutes: 15),
  maxEntries: 30,
  cacheable: (videos) => videos.isNotEmpty,
);

void clearRequestCaches() {
  listingCache.clear();
  relatedCache.clear();
}
