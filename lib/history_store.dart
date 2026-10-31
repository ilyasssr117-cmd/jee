import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';
import 'video_json.dart';

class HistoryEntry {
  const HistoryEntry(this.video, this.playedAt);

  final Video video;
  final DateTime playedAt;
}

class HistoryStore extends ChangeNotifier {
  HistoryStore._();

  static final HistoryStore instance = HistoryStore._();

  static const String _key = 'history_v1';
  static const int _maxItems = 150;

  final List<HistoryEntry> _items = <HistoryEntry>[];
  late final UnmodifiableListView<HistoryEntry> _view =
      UnmodifiableListView<HistoryEntry>(_items);

  List<HistoryEntry> get items => _view;

  void load() {
    _items.clear();
    for (final raw in LocalStore.readList(_key)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final meta = decoded['v'];
        final time = decoded['t'];
        if (meta is! Map<String, dynamic> || time is! int) continue;
        final video = videoFromJson(meta);
        if (video == null) continue;
        _items.add(
          HistoryEntry(video, DateTime.fromMillisecondsSinceEpoch(time)),
        );
      } catch (_) {
      }
    }
    _items.sort((a, b) => b.playedAt.compareTo(a.playedAt));
  }

  void record(Video video) {
    _items.removeWhere((entry) => entry.video.id == video.id);
    _items.insert(0, HistoryEntry(video.withoutStream(), DateTime.now()));
    while (_items.length > _maxItems) {
      _items.removeLast();
    }
    _persist();
    notifyListeners();
  }

  void remove(String id) {
    final before = _items.length;
    _items.removeWhere((entry) => entry.video.id == id);
    if (_items.length == before) return;
    _persist();
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    _persist();
    notifyListeners();
  }

  void _persist() => LocalStore.writeList(
        _key,
        _items
            .map(
              (entry) => jsonEncode(<String, dynamic>{
                'v': videoToJson(entry.video),
                't': entry.playedAt.millisecondsSinceEpoch,
              }),
            )
            .toList(),
      );
}
