import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';

class FavoriteModelsStore extends ChangeNotifier {
  FavoriteModelsStore._();

  static final FavoriteModelsStore instance = FavoriteModelsStore._();

  static const String _key = 'favorite_models_v1';
  static const int _maxItems = 100;

  final List<ModelRef> _items = <ModelRef>[];

  List<ModelRef> get items => List<ModelRef>.unmodifiable(_items);

  void init() {
    _items.clear();
    final raw = LocalStore.readString(_key);
    if (raw != null && raw.isNotEmpty && raw.length <= 512 * 1024) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded.take(_maxItems * 3)) {
            if (entry is! Map) continue;
            final name = entry['name'];
            final url = entry['url'];
            if (name is! String ||
                name.isEmpty ||
                name.length > 200 ||
                url is! String ||
                !_isSafeHttpUrl(url)) {
              continue;
            }
            if (_items.any((item) => item.url == url)) continue;
            final image = entry['image'];
            _items.add(
              ModelRef(
                name: name,
                url: url,
                imageUrl: image is String && _isSafeHttpUrl(image)
                    ? image
                    : null,
              ),
            );
            if (_items.length >= _maxItems) break;
          }
        }
      } catch (error) {
        debugPrint('[FAVMODELS] Saved list unreadable: ${error.runtimeType}');
      }
    }
    notifyListeners();
  }

  static bool _isSafeHttpUrl(String value) {
    if (value.isEmpty || value.length > 4096) return false;
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  bool isFavorite(String modelUrl) => _items.any((m) => m.url == modelUrl);

  bool toggle(ModelRef model) {
    final index = _items.indexWhere((m) => m.url == model.url);
    final nowFavorite = index < 0;
    if (nowFavorite) {
      if (!_isSafeHttpUrl(model.url) ||
          model.name.isEmpty ||
          model.name.length > 200) {
        return false;
      }
      _items.insert(
        0,
        ModelRef(
          name: model.name,
          url: model.url,
          imageUrl: model.imageUrl != null && _isSafeHttpUrl(model.imageUrl!)
              ? model.imageUrl
              : null,
        ),
      );
      if (_items.length > _maxItems) _items.removeLast();
    } else {
      _items.removeAt(index);
    }
    _save();
    notifyListeners();
    return nowFavorite;
  }

  void updateImage(String modelUrl, String? imageUrl) {
    if (imageUrl == null || !_isSafeHttpUrl(imageUrl)) return;
    final index = _items.indexWhere((m) => m.url == modelUrl);
    if (index < 0 || _items[index].imageUrl == imageUrl) return;
    _items[index] = _items[index].withImage(imageUrl);
    _save();
    notifyListeners();
  }

  void _save() => LocalStore.writeString(
    _key,
    jsonEncode(<Object?>[
      for (final m in _items)
        <String, Object?>{'name': m.name, 'url': m.url, 'image': m.imageUrl},
    ]),
  );
}
