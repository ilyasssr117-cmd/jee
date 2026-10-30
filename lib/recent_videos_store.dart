import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';

class RecentVideosStore extends ChangeNotifier {
  RecentVideosStore._();

  static final RecentVideosStore instance = RecentVideosStore._();
  static const String _key = 'recent_videos_v1';
  static const int _maxItems = 150;

  final List<Video> _items = <Video>[];
  final Set<String> _ids = <String>{};
  late final UnmodifiableListView<Video> _view =
      UnmodifiableListView<Video>(_items);

  List<Video> get items => _view;

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
      }
    }
    if (_items.length > _maxItems) _items.removeRange(_maxItems, _items.length);
  }

  void record(Video video) {
    final safeVideo = video.copyWith(streamUrl: '', previewUrl: '');
    _ids.remove(safeVideo.id);
    _items.removeWhere((item) => item.id == safeVideo.id);
    _ids.add(safeVideo.id);
    _items.insert(0, safeVideo);
    while (_items.length > _maxItems) {
      _ids.remove(_items.removeLast().id);
    }
    _persist();
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    _ids.clear();
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
