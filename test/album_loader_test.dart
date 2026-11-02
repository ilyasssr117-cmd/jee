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
        0 => AlbumPhotosPage(
            photos: List<AlbumPhoto>.generate(100, _photo),
            totalCount: 100,
          ),
        1 => AlbumPhotosPage(
            photos: <AlbumPhoto>[
              _photo(99), // overlap between pages must not add a duplicate.
              ...List<AlbumPhoto>.generate(100, (index) => _photo(index + 100)),
            ],
            totalCount: 200,
          ),
        2 => AlbumPhotosPage(
            photos:
                List<AlbumPhoto>.generate(100, (index) => _photo(index + 200)),
            totalCount: 300,
          ),
        _ => const AlbumPhotosPage(photos: <AlbumPhoto>[]),
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

  test(
      'reported album total is shown after one batch without fetching the rest',
      () async {
    var calls = 0;
    final loader = AlbumLoader(
      _album,
      fetchPage: (_, {required chunk}) async {
        calls++;
        return AlbumPhotosPage(
          photos: List<AlbumPhoto>.generate(100, _photo),
          totalCount: 1247,
        );
      },
    );
    addTearDown(loader.dispose);

    await loader.load();

    expect(loader.totalCount, 1247);
    expect(loader.photos, hasLength(100));
    expect(loader.countLabel, '1,247 photos');
    expect(calls, 1);
  });

  test('album-list total is available before opening the first image batch',
      () {
    final album = AlbumRef(
      id: _album.id,
      title: _album.title,
      url: _album.url,
      totalCount: 100,
    );
    final loader = AlbumLoader(
      album,
      fetchPage: (_, {required chunk}) async => AlbumPhotosPage(
        photos: List<AlbumPhoto>.generate(100, _photo),
      ),
    );
    addTearDown(loader.dispose);

    expect(loader.photos, isEmpty);
    expect(loader.countLabel, '100 photos');
  });

  test('only one album page request can run at a time', () async {
    final response = Completer<AlbumPhotosPage>();
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
    response.complete(AlbumPhotosPage(photos: <AlbumPhoto>[_photo(0)]));
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
