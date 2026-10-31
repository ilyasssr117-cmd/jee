import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vxtube_final/local_store.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/offline_listing_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();
  });

  test(
    'offline catalogue cache persists metadata but not signed stream URLs',
    () async {
      const video = Video(
        id: 'offline-video',
        title: 'Offline example',
        streamUrl: 'https://cdn.example.test/movie.mp4?token=private',
        thumbnailUrl: 'https://cdn.example.test/poster.jpg',
        pageUrl: 'https://catalog.example.test/video/1/',
      );

      OfflineListingCache.write('offline-cache-test', const <Video>[video]);
      expect(
        OfflineListingCache.read('offline-cache-test')?.single.title,
        'Offline example',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final raw = LocalStore.readString('offline_listing_pages_v1');
      expect(raw, isNotNull);
      expect(raw, contains('Offline example'));
      expect(raw, isNot(contains('token=private')));
      expect(raw, isNot(contains('movie.mp4')));
    },
  );
}
