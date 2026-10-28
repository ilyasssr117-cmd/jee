import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_tube/favorite_models_store.dart';
import 'package:watch_tube/local_store.dart';
import 'package:watch_tube/models.dart';

void main() {
  const model = ModelRef(
    name: 'Playwithanny',
    url: 'https://x.example.test/models/playwithanny/',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();
    FavoriteModelsStore.instance.init();
  });

  test('a model can be added and removed', () {
    final store = FavoriteModelsStore.instance;
    expect(store.isFavorite(model.url), isFalse);

    expect(store.toggle(model), isTrue);
    expect(store.isFavorite(model.url), isTrue);
    expect(store.items.single.name, 'Playwithanny');

    expect(store.toggle(model), isFalse);
    expect(store.items, isEmpty);
  });

  test('favourite models (and their photo) survive a restart', () {
    final store = FavoriteModelsStore.instance;
    store.toggle(model);
    store.updateImage(model.url, 'https://x.example.test/contents/m.jpg');

    store.init();

    expect(store.items, hasLength(1));
    expect(store.items.single.imageUrl, 'https://x.example.test/contents/m.jpg');
  });

  test('newest favourite comes first', () {
    final store = FavoriteModelsStore.instance;
    store.toggle(model);
    store.toggle(const ModelRef(name: 'Second', url: 'https://x.example.test/models/second/'));
    expect(store.items.map((m) => m.name), <String>['Second', 'Playwithanny']);
  });
}
