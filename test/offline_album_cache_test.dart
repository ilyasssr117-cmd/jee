import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vxtube_final/local_store.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/offline_album_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();
    OfflineAlbumCache.init();
  });

  test(
    'offline album cache keeps safe metadata but omits image URLs',
    () async {
      const album = AlbumRef(
        id: 'album-1',
        title: 'Offline album',
        url: 'https://catalog.example.test/albums/1/',
        modelName: 'Example',
        thumbnailUrl: 'https://cdn.example.test/cover.jpg?token=temporary',
      );

      OfflineAlbumCache.write('offline-album-test', const <AlbumRef>[album]);
      expect(
        OfflineAlbumCache.read('offline-album-test')?.single.title,
        'Offline album',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final raw = LocalStore.readString('offline_album_pages_v1');
      expect(raw, isNotNull);
      expect(raw, contains('Offline album'));
      expect(raw, isNot(contains('cdn.example.test')));
      expect(raw, isNot(contains('token=temporary')));
    },
  );

  test('offline album cache rejects unsafe source URLs', () async {
    OfflineAlbumCache.write('unsafe-album-test', const <AlbumRef>[
      AlbumRef(id: 'bad', title: 'Bad album', url: 'file:///private/photo'),
    ]);
    expect(OfflineAlbumCache.read('unsafe-album-test'), isNull);
  });
}
