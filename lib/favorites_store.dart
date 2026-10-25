import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';

/// Favourite videos, newest first, persisted locally.
///
/// Only list-level metadata is stored. Stream URLs are never saved because
/// they expire; the player re-resolves them from the page URL when needed.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  static const String _key = 'favorites_v1';
  static const int _maxItems = 300;

  final List<Video> _items = <Video>[];
  final Set<String> _ids = <String>{};
  late final UnmodifiableListView<Video> _view =
      UnmodifiableListView<Video>(_items);

  List<Video> get items => _view;

  bool isFavorite(String id) => _ids.contains(id);

  void load() {
    _items.clear();
    _ids.clear();
    for (final raw in LocalStore.readList(_key)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final video = _decode(decoded);
        if (video != null && _ids.add(video.id)) _items.add(video);
      } catch (_) {
        // Skip a corrupt entry instead of losing the whole list.
      }
    }
  }

  /// Returns the new state: true when [video] is now a favourite.
  bool toggle(Video video) {
    if (_ids.contains(video.id)) {
      remove(video.id);
      return false;
    }
    add(video);
    return true;
  }

  void add(Video video) {
    if (!_ids.add(video.id)) return;
    _items.insert(0, video.copyWith(streamUrl: ''));
    while (_items.length > _maxItems) {
      _ids.remove(_items.removeLast().id);
    }
    _persist();
    notifyListeners();
  }

  void remove(String id) {
    if (!_ids.remove(id)) return;
    _items.removeWhere((video) => video.id == id);
    _persist();
    notifyListeners();
  }

  void _persist() => LocalStore.writeList(
        _key,
        _items.map((video) => jsonEncode(_encode(video))).toList(),
      );

  static Map<String, dynamic> _encode(Video video) => <String, dynamic>{
        'id': video.id,
        'title': video.title,
        'thumb': video.thumbnailUrl,
        'page': video.pageUrl,
        'duration': video.duration,
        'views': video.views,
        'likes': video.likes,
        'date': video.date,
        'category': video.category,
      };

  static Video? _decode(Map<String, dynamic> map) {
    final id = map['id'];
    final title = map['title'];
    if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
      return null;
    }
    String text(String key) => map[key] is String ? map[key] as String : '';
    String? optional(String key) {
      final value = text(key);
      return value.isEmpty ? null : value;
    }

    return Video(
      id: id,
      title: title,
      thumbnailUrl: optional('thumb'),
      pageUrl: optional('page'),
      duration: text('duration'),
      views: text('views'),
      likes: text('likes'),
      date: text('date'),
      category: text('category').isEmpty ? 'Video' : text('category'),
    );
  }
}
