import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';

class FavoriteModelsStore extends ChangeNotifier {
  FavoriteModelsStore._();

  static final FavoriteModelsStore instance = FavoriteModelsStore._();

  static const String _key = 'favorite_models_v1';

  final List<ModelRef> _items = <ModelRef>[];

  List<ModelRef> get items => List<ModelRef>.unmodifiable(_items);

  void init() {
    _items.clear();
    final raw = LocalStore.readString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final name = entry['name'];
            final url = entry['url'];
            if (name is! String || url is! String || url.isEmpty) continue;
            final image = entry['image'];
            _items.add(ModelRef(
              name: name,
              url: url,
              imageUrl: image is String && image.isNotEmpty ? image : null,
            ));
          }
        }
      } catch (error) {
        debugPrint('[FAVMODELS] Saved list unreadable: $error');
      }
    }
    notifyListeners();
  }

  bool isFavorite(String modelUrl) => _items.any((m) => m.url == modelUrl);

  bool toggle(ModelRef model) {
    final index = _items.indexWhere((m) => m.url == model.url);
    final nowFavorite = index < 0;
    if (nowFavorite) {
      _items.insert(0, model);
    } else {
      _items.removeAt(index);
    }
    _save();
    notifyListeners();
    return nowFavorite;
  }

  void updateImage(String modelUrl, String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return;
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
