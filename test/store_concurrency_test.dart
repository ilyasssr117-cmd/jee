import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vxtube_final/favorites_store.dart';
import 'package:vxtube_final/history_store.dart';
import 'package:vxtube_final/local_store.dart';
import 'package:vxtube_final/models.dart';

/// Stress tests for rapid store mutations (transformation Phase 7.3).
///
/// The audit flagged unawaited store writes as a *potential* race.
/// These tests pin the actual contract: synchronous in-memory mutation
/// with write-through persistence must end in the same state as the
/// equivalent sequential operations, no matter how fast toggles land.
void main() {
  Video video(String id) => Video(
        id: id,
        title: 'Video $id',
        pageUrl: 'https://x.example.test/videos/$id/',
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();
    FavoritesStore.instance.load();
    HistoryStore.instance.load();
  });

  test('100 rapid favorite toggles end in the sequential state', () {
    final store = FavoritesStore.instance;
    final v = video('a');
    for (var i = 0; i < 100; i++) {
      store.toggle(v);
    }
    // Even number of toggles: not a favorite, nothing persisted.
    expect(store.isFavorite('a'), isFalse);
    expect(store.items, isEmpty);

    store.toggle(v);
    expect(store.isFavorite('a'), isTrue);
    expect(store.items, hasLength(1));
  });

  test('rapid toggles across many videos keep every item once', () {
    final store = FavoritesStore.instance;
    for (var round = 0; round < 5; round++) {
      for (var i = 0; i < 20; i++) {
        store.toggle(video('v$i'));
      }
    }
    // 5 toggles each = odd = all favorited, no duplicates.
    expect(store.items, hasLength(20));
    expect(store.items.map((v) => v.id).toSet(), hasLength(20));
  });

  test('rapid history recording keeps the most recent first', () {
    final store = HistoryStore.instance;
    for (var i = 0; i < 30; i++) {
      store.record(video('h$i'));
    }
    expect(store.items.first.video.id, 'h29');
    // Re-recording an existing item moves it to the front, once.
    store.record(video('h0'));
    expect(store.items.first.video.id, 'h0');
    expect(store.items.where((e) => e.video.id == 'h0'), hasLength(1));
  });
}
