import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watch_tube/local_store.dart';
import 'package:watch_tube/models.dart';
import 'package:watch_tube/photo_store.dart';

final List<int> _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(24, 7)];

const AlbumRef _album = AlbumRef(
  id: 'x.example.test/albums/37/pictures/',
  title: 'Pictures',
  url: 'https://x.example.test/albums/37/pictures/',
);

AlbumPhoto _photo(int n) => AlbumPhoto(
      id: '0/37/$n.jpg',
      thumbUrl: 'https://cdn.example.test/t/$n.jpg',
      fullUrl: 'https://x.example.test/get_image/10/h$n/sources/0/37/$n.jpg/?i-acctoken=T',
    );

void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalStore.init();
    root = Directory.systemTemp.createTempSync('photo_store_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MockClient okClient() => MockClient((request) async {
        expect(request.headers['Referer'], 'https://x.example.test/');
        return http.Response.bytes(_jpeg, 200);
      });

  test('saves photos into an album folder and remembers them', () async {
    final store = PhotoStore.forTesting(root: root, client: okClient());

    final saved = await store.savePhotos(
      _album,
      <AlbumPhoto>[_photo(29946), _photo(29944), _photo(29945)],
      modelName: 'Playwithanny',
    );

    expect(saved, 3);
    final album = store.album(_album.id)!;
    expect(album.modelName, 'Playwithanny');
    expect(album.photos.map((p) => p.id),
        <String>['0/37/29944.jpg', '0/37/29945.jpg', '0/37/29946.jpg']);
    for (final photo in album.photos) {
      expect(store.fileOf(album, photo).existsSync(), isTrue);
      expect(store.fileOf(album, photo).path, endsWith('.jpg'));
    }
    expect(store.isSaved(_album.id, '0/37/29944.jpg'), isTrue);
    expect(store.jobFor(_album.id), isNull);
    expect(store.totalPhotos, 3);
  });

  test('photos that are already saved are skipped', () async {
    var requests = 0;
    final store = PhotoStore.forTesting(
      root: root,
      client: MockClient((request) async {
        requests++;
        return http.Response.bytes(_jpeg, 200);
      }),
    );

    await store.savePhotos(_album, <AlbumPhoto>[_photo(1), _photo(2)]);
    final again = await store.savePhotos(
      _album,
      <AlbumPhoto>[_photo(1), _photo(2), _photo(3)],
    );

    expect(again, 1);
    expect(requests, 3);
    expect(store.album(_album.id)!.photos, hasLength(3));
  });

  test('an error page is not saved as a picture', () async {
    final store = PhotoStore.forTesting(
      root: root,
      client: MockClient((request) async => request.url.path.contains('/h2/')
          ? http.Response('<html>expired</html>', 200)
          : http.Response.bytes(_jpeg, 200)),
    );

    final saved = await store.savePhotos(_album, <AlbumPhoto>[_photo(1), _photo(2)]);

    expect(saved, 1);
    expect(store.isSaved(_album.id, '0/37/2.jpg'), isFalse);
  });

  test('an album where every download failed is not kept', () async {
    final store = PhotoStore.forTesting(
      root: root,
      client: MockClient((request) async => http.Response('nope', 403)),
    );

    final saved = await store.savePhotos(_album, <AlbumPhoto>[_photo(1)]);

    expect(saved, 0);
    expect(store.albums, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test('saved albums survive a restart', () async {
    final first = PhotoStore.forTesting(root: root, client: okClient());
    await first.savePhotos(_album, <AlbumPhoto>[_photo(1), _photo(2)]);

    final second = PhotoStore.forTesting(root: root);
    second.load();

    expect(second.albums, hasLength(1));
    expect(second.albums.single.title, 'Pictures');
    expect(second.albums.single.photos, hasLength(2));
  });

  test('removing a photo and then the album deletes the files', () async {
    final store = PhotoStore.forTesting(root: root, client: okClient());
    await store.savePhotos(_album, <AlbumPhoto>[_photo(1), _photo(2)]);
    final folder = Directory('${root.path}/${store.album(_album.id)!.dir}');

    await store.removePhoto(_album.id, '0/37/1.jpg');
    expect(store.album(_album.id)!.photos, hasLength(1));
    expect(folder.listSync(), hasLength(1));

    await store.removeAlbum(_album.id);
    expect(store.albums, isEmpty);
    expect(folder.existsSync(), isFalse);
  });
}
