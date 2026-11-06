import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'analytics_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'video_json.dart';
import 'services/remote_config_service.dart';

class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  static const String _key = 'favorites_v1';
  static const int _maxItems = 300;

  final List<Video> _items = <Video>[];
  final Set<String> _ids = <String>{};
  late final UnmodifiableListView<Video> _view = UnmodifiableListView<Video>(
    _items,
  );

  List<Video> get items => _view;

  bool isFavorite(String id) => _ids.contains(id);

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

  bool toggle(Video video) {
    if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) {
      return _ids.contains(video.id);
    }
    if (_ids.contains(video.id)) {
      remove(video.id);
      return false;
    }
    add(video);
    return true;
  }

  void add(Video video) {
    if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) return;
    if (!_ids.add(video.id)) return;
    AnalyticsService.instance.trackFavorite(video.id, added: true);
    _items.insert(0, video.copyWith(streamUrl: ''));
    while (_items.length > _maxItems) {
      _ids.remove(_items.removeLast().id);
    }
    _persist();
    notifyListeners();
  }

  void remove(String id) {
    if (!_ids.remove(id)) return;
    AnalyticsService.instance.trackFavorite(id, added: false);
    _items.removeWhere((video) => video.id == id);
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
