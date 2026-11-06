import 'dart:collection';
import 'dart:convert';

import 'favorites_store.dart';
import 'services/remote_config_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_source.dart';

const String kReelUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 '
    'Mobile/15E148 Safari/604.1';

const String kReelMediaOrigin = 'https://tik.porn';

const Map<String, String> kReelMediaHeaders = {
  'User-Agent': kReelUserAgent,
  'Referer': '$kReelMediaOrigin/',
  'Origin': kReelMediaOrigin,
  'Accept': '*/*',
};

String reelCompact(num n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '${n.toInt()}';
}

String reelClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

class ReelItem {
  const ReelItem({
    required this.id,
    required this.videoUrl,
    this.title = '',
    this.thumbUrl,
    this.avatarUrl,
    this.author = '',
    this.views = 0,
    this.likes = 0,
    this.durationSec = 0,
    this.tags = const <String>[],
    this.fallbackUrl,
    this.downloadUrl,
  });

  final String id;
  final String videoUrl;
  final String? fallbackUrl;
  final String? downloadUrl;
  final String title;
  final String? thumbUrl;
  final String? avatarUrl;
  final String author;
  final int views;

  /// Like count reported by the service (0 when the service sends none).
  final int likes;
  final int durationSec;
  final List<String> tags;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': videoUrl,
        'fallback': fallbackUrl,
        'download': downloadUrl,
        'title': title,
        'thumb': thumbUrl,
        'avatar': avatarUrl,
        'author': author,
        'views': views,
        'likes': likes,
        'duration': durationSec,
        'tags': tags,
      };

  static ReelItem? fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final url = map['url'];
    if (id is! String || id.isEmpty || url is! String || url.isEmpty) {
      return null;
    }
    String? optional(String key) {
      final value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    int number(String key) => map[key] is num ? (map[key] as num).toInt() : 0;

    return ReelItem(
      id: id,
      videoUrl: url,
      fallbackUrl: optional('fallback'),
      downloadUrl: optional('download'),
      title: map['title'] is String ? map['title'] as String : '',
      thumbUrl: optional('thumb'),
      avatarUrl: optional('avatar'),
      author: map['author'] is String ? map['author'] as String : '',
      views: number('views'),
      likes: number('likes'),
      durationSec: number('duration'),
      tags: map['tags'] is List
          ? <String>[
              for (final tag in map['tags'] as List)
                if (tag is String) tag,
            ]
          : const <String>[],
    );
  }
}

/// A "like" on a reel is simply a favorite. The catalogue entry lives in
/// [FavoritesStore] (so it shows up in the Library), while the playable data
/// of the reel is kept here so it can be opened again later.
class ReelFavorites {
  ReelFavorites._();

  static final ReelFavorites instance = ReelFavorites._();

  static const String _key = 'reel_favorites_v1';
  static const int _maxItems = 300;

  final LinkedHashMap<String, ReelItem> _items =
      LinkedHashMap<String, ReelItem>();
  bool _loaded = false;

  static String videoId(String reelId) => 'reel_$reelId';

  static Video videoOf(ReelItem item) => Video(
        id: videoId(item.id),
        title: item.title.isEmpty
            ? (item.author.isEmpty ? 'Reel' : 'Reel by @${item.author}')
            : item.title,
        thumbnailUrl: item.thumbUrl,
        duration: reelClock(Duration(seconds: item.durationSec)),
        views: item.views > 0 ? reelCompact(item.views) : '',
        category: 'Reels',
      );

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    for (final raw in LocalStore.readList(_key).take(_maxItems * 2)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final item = ReelItem.fromJson(decoded);
        if (item != null) _items[item.id] = item;
      } catch (_) {}
    }
  }

  void _persist() => LocalStore.writeList(
        _key,
        _items.values.map((item) => jsonEncode(item.toJson())).toList(),
      );

  bool isLiked(String reelId) =>
      FavoritesStore.instance.isFavorite(videoId(reelId));

  /// Adds the reel to favorites. Returns false when it was already there.
  bool like(ReelItem item) {
    if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) {
      return false;
    }
    _ensureLoaded();
    if (isLiked(item.id)) return false;
    _items.remove(item.id);
    _items[item.id] = item;
    while (_items.length > _maxItems) {
      _items.remove(_items.keys.first);
    }
    _persist();
    FavoritesStore.instance.add(videoOf(item));
    return true;
  }

  void unlike(String reelId) {
    if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) return;
    _ensureLoaded();
    FavoritesStore.instance.remove(videoId(reelId));
    if (_items.remove(reelId) != null) _persist();
  }

  /// Returns the new liked state.
  bool toggle(ReelItem item) {
    if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) {
      return isLiked(item.id);
    }
    if (isLiked(item.id)) {
      unlike(item.id);
      return false;
    }
    like(item);
    return true;
  }

  /// Direct playback source for a favorited reel (or null for any other id).
  PlaybackSource? sourceFor(String videoId) {
    if (!videoId.startsWith('reel_')) return null;
    _ensureLoaded();
    final item = _items[videoId.substring(5)];
    if (item == null) return null;
    return PlaybackSource(item.videoUrl, kReelMediaHeaders);
  }
}
