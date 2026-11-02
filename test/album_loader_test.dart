import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/album_page.dart';
import 'package:vxtube_final/models.dart';

const _album = AlbumRef(
  id: 'catalog.test/albums/a/',
  title: 'Album',
  url: 'https://catalog.test/albums/a/',
);

AlbumPhoto _photo(int index) => AlbumPhoto(
      id: 'photo-$index',
      thumbUrl: 'https://cdn.test/thumb-$index.jpg',
      fullUrl: 'https://cdn.test/full-$index.jpg',
    );

void main() {
  test('album pages append beyond 100 and update the discovered count',
      () async {
    final loader = AlbumLoader(
      _album,
      fetchPage: (_, {required chunk}) async => switch (chunk) {
        0 => List<AlbumPhoto>.generate(100, _photo),
        1 => <AlbumPhoto>[
            _photo(99), // overlap between pages must not add a duplicate.
            ...List<AlbumPhoto>.generate(100, (index) => _photo(index + 100)),
          ],
        2 => List<AlbumPhoto>.generate(100, (index) => _photo(index + 200)),
        _ => const <AlbumPhoto>[],
      },
    );
    addTearDown(loader.dispose);

    await loader.load();
    expect(loader.photos, hasLength(100));
    expect(loader.countLabel, '100 photos');

    await loader.load();
    expect(loader.photos, hasLength(200));
    expect(loader.photos.map((photo) => photo.id).toSet(), hasLength(200));
    expect(loader.countLabel, '200 photos');

    await loader.load();
    expect(loader.photos, hasLength(300));
    expect(loader.countLabel, '300 photos');

    await loader.load();
    expect(loader.finished, isTrue);
    expect(loader.photos, hasLength(300));
  });

  test('only one album page request can run at a time', () async {
    final response = Completer<List<AlbumPhoto>>();
    var calls = 0;
    final loader = AlbumLoader(
      _album,
      fetchPage: (_, {required chunk}) {
        calls++;
        return response.future;
      },
    );
    addTearDown(loader.dispose);

    final first = loader.load();
    final second = loader.load();
    expect(calls, 1);
    response.complete(<AlbumPhoto>[_photo(0)]);
    await Future.wait(<Future<void>>[first, second]);
    expect(loader.photos, hasLength(1));
  });

  test('live album data restores a thumbnail omitted from offline metadata',
      () {
    const cached = _album;
    final live = AlbumRef(
      id: _album.id,
      title: 'Fresh title',
      url: _album.url,
      thumbnailUrl: 'https://cdn.test/cover.jpg',
      modelName: 'Model',
    );

    final refreshed = cached.refreshedBy(live);
    expect(refreshed.thumbnailUrl, live.thumbnailUrl);
    expect(refreshed.title, 'Fresh title');
    expect(refreshed.modelName, 'Model');
  });
}
