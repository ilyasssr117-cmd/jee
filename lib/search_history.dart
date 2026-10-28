import 'package:flutter/foundation.dart';

import 'local_store.dart';

class SearchHistory extends ChangeNotifier {
  SearchHistory._();

  static final SearchHistory instance = SearchHistory._();

  static const String _key = 'recent_searches_v1';
  static const int maxItems = 4;

  final List<String> _items = <String>[];

  List<String> get items => List<String>.unmodifiable(_items);

  static String normalize(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  void load() {
    _items
      ..clear()
      ..addAll(LocalStore.readList(_key).take(maxItems));
  }

  void add(String query) {
    final value = normalize(query);
    if (value.isEmpty) return;
    final lower = value.toLowerCase();
    if (_items.isNotEmpty && _items.first == value) return;
    _items
      ..removeWhere((item) => item.toLowerCase() == lower)
      ..insert(0, value);
    if (_items.length > maxItems) _items.removeRange(maxItems, _items.length);
    _persist();
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    _persist();
    notifyListeners();
  }

  void remove(String query) {
    final before = _items.length;
    _items.remove(query);
    if (_items.length == before) return;
    _persist();
    notifyListeners();
  }

  void _persist() => LocalStore.writeList(_key, _items);
}
