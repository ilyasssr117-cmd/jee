import 'dart:collection';

import 'models.dart';

class TtlCache<V> {
  TtlCache({
    this.ttl = const Duration(minutes: 5),
    this.maxEntries = 40,
    this.cacheable,
  });

  final Duration ttl;
  final int maxEntries;

  final bool Function(V value)? cacheable;

  final LinkedHashMap<String, _Entry<V>> _entries =
      LinkedHashMap<String, _Entry<V>>();
  final Map<String, Future<V>> _running = <String, Future<V>>{};

  V? peek(String key) {
    final hit = _entries[key];
    if (hit != null && DateTime.now().isBefore(hit.expires)) return hit.value;
    return null;
  }

  Future<V> fetch(
    String key,
    Future<V> Function() loader, {
    bool force = false,
  }) {
    if (!force) {
      final hit = _entries[key];
      if (hit != null && DateTime.now().isBefore(hit.expires)) {
        _entries.remove(key);
        _entries[key] = hit;
        return Future<V>.value(hit.value);
      }
      final running = _running[key];
      if (running != null) return running;
    }

    late final Future<V> tracked;
    final future = loader().then((value) {
      if (identical(_running[key], tracked) &&
          (cacheable == null || cacheable!(value))) {
        _entries.remove(key);
        _entries[key] = _Entry<V>(value, DateTime.now().add(ttl));
        while (_entries.length > maxEntries) {
          _entries.remove(_entries.keys.first);
        }
      }
      return value;
    });
    tracked = future.whenComplete(() {
      if (identical(_running[key], tracked)) {
        _running.remove(key);
      }
    });
    _running[key] = tracked;
    return tracked;
  }

  void clear() {
    _entries.clear();
    _running.clear();
  }
}

class _Entry<V> {
  const _Entry(this.value, this.expires);

  final V value;
  final DateTime expires;
}

final TtlCache<List<Video>> listingCache =
    TtlCache<List<Video>>(ttl: const Duration(minutes: 4), maxEntries: 60);

final TtlCache<List<Video>> relatedCache =
    TtlCache<List<Video>>(ttl: const Duration(minutes: 15), maxEntries: 30);

final TtlCache<List<ModelRef>> modelsCache =
    TtlCache<List<ModelRef>>(ttl: const Duration(minutes: 30), maxEntries: 60);

final TtlCache<PeopleSearchResult> peopleCache = TtlCache<PeopleSearchResult>(
  ttl: const Duration(minutes: 10),
  maxEntries: 30,
  cacheable: (result) => !result.isEmpty,
);

final TtlCache<List<AlbumRef>> albumsCache = TtlCache<List<AlbumRef>>(
  ttl: const Duration(minutes: 10),
  maxEntries: 80,
  cacheable: (albums) => albums.isNotEmpty,
);

final TtlCache<ModelProfile> profileCache =
    TtlCache<ModelProfile>(ttl: const Duration(hours: 6), maxEntries: 120);

void clearRequestCaches() {
  profileCache.clear();
  peopleCache.clear();
  albumsCache.clear();
  listingCache.clear();
  relatedCache.clear();
  modelsCache.clear();
}
