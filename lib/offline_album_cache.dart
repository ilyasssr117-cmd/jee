import 'dart:collection';
import 'dart:convert';

import 'local_store.dart';
import 'models.dart';

/// Bounded persistent cache for album catalogue metadata.
/// Image URLs are intentionally omitted because many are signed/temporary.
abstract final class OfflineAlbumCache {
  static const String _storageKey = 'offline_album_pages_v1';
  static const int _maxPages = 12;
  static const int _maxItemsPerPage = 80;
  static const int _maxKeyLength = 256;
  static const int _maxStoredBytes = 1536 * 1024;
  static const Duration _maxAge = Duration(days: 7);

  static final LinkedHashMap<String, _AlbumPage> _pages =
      LinkedHashMap<String, _AlbumPage>();
  static Future<void> _writeQueue = Future<void>.value();
  static bool _persistScheduled = false;
  static bool _persistDirty = false;
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    final raw = LocalStore.readString(_storageKey);
    if (raw == null ||
        raw.isEmpty ||
        utf8.encode(raw).length > _maxStoredBytes) {
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
        final rawAlbums = item['albums'];
        if (key is! String ||
            key.isEmpty ||
            key.length > _maxKeyLength ||
            savedAt is! int ||
            rawAlbums is! List) {
          continue;
        }
        final timestamp = DateTime.fromMillisecondsSinceEpoch(savedAt);
        if (timestamp.isAfter(now) || now.difference(timestamp) > _maxAge) {
          continue;
        }
        final albums = <AlbumRef>[];
        for (final rawAlbum in rawAlbums.take(_maxItemsPerPage)) {
          if (rawAlbum is! Map) continue;
          final album = _decodeAlbum(Map<String, dynamic>.from(rawAlbum));
          if (album != null) albums.add(album);
        }
        if (albums.isNotEmpty) {
          _pages[key] = _AlbumPage(
            timestamp,
            List<AlbumRef>.unmodifiable(albums),
          );
        }
      }
      _trim();
    } catch (_) {
      _pages.clear();
    }
  }

  static List<AlbumRef>? read(String key) {
    init();
    if (key.isEmpty || key.length > _maxKeyLength) return null;
    final page = _pages.remove(key);
    if (page == null) return null;
    if (DateTime.now().difference(page.savedAt) > _maxAge) {
      _schedulePersist();
      return null;
    }
    _pages[key] = page;
    return page.albums;
  }

  static void write(String key, List<AlbumRef> albums) {
    init();
    if (key.isEmpty || key.length > _maxKeyLength) return;
    if (albums.isEmpty) {
      _pages.remove(key);
      _schedulePersist();
      return;
    }
    final safe = <AlbumRef>[];
    for (final album in albums.take(_maxItemsPerPage)) {
      final url = Uri.tryParse(album.url);
      if (album.id.isEmpty ||
          album.id.length > 512 ||
          album.title.isEmpty ||
          album.title.length > 300 ||
          url == null ||
          (url.scheme != 'http' && url.scheme != 'https') ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        continue;
      }
      safe.add(
        AlbumRef(
          id: album.id,
          title: album.title,
          url: album.url,
          modelName: album.modelName == null
              ? null
              : _bounded(album.modelName!, 256),
        ),
      );
    }
    if (safe.isEmpty) return;
    _pages.remove(key);
    _pages[key] = _AlbumPage(DateTime.now(), List<AlbumRef>.unmodifiable(safe));
    _trim();
    _schedulePersist();
  }

  static String _bounded(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);

  static AlbumRef? _decodeAlbum(Map<String, dynamic> raw) {
    final id = raw['id'];
    final title = raw['title'];
    final url = raw['url'];
    final model = raw['model'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 512 ||
        title is! String ||
        title.isEmpty ||
        title.length > 300 ||
        url is! String ||
        url.length > 4096 ||
        (model != null && model is! String)) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return AlbumRef(
      id: id,
      title: title,
      url: url,
      modelName: model is String ? _bounded(model, 256) : null,
    );
  }

  static String _encode() => jsonEncode(<Map<String, Object?>>[
    for (final entry in _pages.entries)
      <String, Object?>{
        'key': entry.key,
        'savedAt': entry.value.savedAt.millisecondsSinceEpoch,
        'albums': <Map<String, Object?>>[
          for (final album in entry.value.albums)
            <String, Object?>{
              'id': album.id,
              'title': album.title,
              'url': album.url,
              'model': album.modelName,
            },
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
          while (_persistDirty) {
            _persistDirty = false;
            await Future<void>.delayed(const Duration(milliseconds: 160));
            var snapshot = _encode();
            while (utf8.encode(snapshot).length > _maxStoredBytes &&
                _pages.length > 1) {
              _pages.remove(_pages.keys.first);
              snapshot = _encode();
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

class _AlbumPage {
  const _AlbumPage(this.savedAt, this.albums);

  final DateTime savedAt;
  final List<AlbumRef> albums;
}
