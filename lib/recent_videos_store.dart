import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';
import 'video_json.dart';

class RecentVideosStore extends ChangeNotifier {
  RecentVideosStore._();

  static final RecentVideosStore instance = RecentVideosStore._();
  static const String _key = 'recent_videos_v1';
  static const int _maxItems = 150;

  final List<Video> _items = <Video>[];
  final Set<String> _ids = <String>{};
  late final UnmodifiableListView<Video> _view = UnmodifiableListView<Video>(
    _items,
  );

  List<Video> get items => _view;

  void load() {
    _items.clear();
    _ids.clear();
    for (final raw in LocalStore.readList(_key).take(_maxItems * 3)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final video = _decode(decoded);
        if (video != null && _ids.add(video.id)) _items.add(video);
      } catch (_) {}
    }
    while (_items.length > _maxItems) {
      _ids.remove(_items.removeLast().id);
    }
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

  static Map<String, dynamic> _encode(Video video) => videoToJson(video);

  static Video? _decode(Map<String, dynamic> map) => videoFromJson(map);
}
