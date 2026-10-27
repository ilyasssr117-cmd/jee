import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_tube/models.dart';
import 'package:watch_tube/scraper.dart';

const _card = '''
<div class="thumbs__list">
  <div class="item thumb">
    <a href="/video/%ID%/" title="Video %ID%"><img data-src="/i/%ID%.jpg" alt="Video %ID%"></a>
    <ul><li>10:00</li></ul>
  </div>
</div>
''';

String _listing(List<String> ids) =>
    '<html><body>${ids.map((id) => _card.replaceAll('%ID%', id)).join()}</body></html>';

String _person({String? image}) => '''
<html><head>
<script type="application/ld+json">
{ "@context": "https://schema.org", "@type": "Person", "name": "Playwithanny",
  "url": "https://x.example.test/models/playwithanny/"
  ${image == null ? '' : ', "image": "$image"'} ,
  "gender": "Male", "jobTitle": "Actor" }
</script></head><body>%CARDS%</body></html>
''';

Scraper _scraper(MockClient client) => Scraper(
      const ScraperConfig(baseUrl: 'https://x.example.test'),
      client: client,
    );

void main() {
  test('a video page lists its models', () async {
    final client = MockClient((request) async => http.Response('''
      <html><body>
        <div class="media-info__row media-models">
          <div class="media-info__lists"><div class="media-info__lists-row">
            <span class="media-info__label">Models:</span>
            <div class="media-info__buttons">
              <a class="btn" href="https://x.example.test/models/playwithanny/">Playwithanny</a>
              <a class="btn" href="/models/second-one/">Second One</a>
              <a class="btn" href="/models/playwithanny/">Playwithanny</a>
              <a class="btn" href="/categories/tag/">Not a model</a>
            </div>
          </div></div>
        </div>
      </body></html>''', 200));
    final scraper = _scraper(client);

    final models = await scraper.videoModels(const Video(
      id: 'v',
      title: 'v',
      pageUrl: 'https://x.example.test/video/1/',
    ));

    expect(models.map((m) => m.name), <String>['Playwithanny', 'Second One']);
    expect(models.first.url, 'https://x.example.test/models/playwithanny/');
    expect(models.last.url, 'https://x.example.test/models/second-one/');
    scraper.close();
  });

  test('a video page without models gives an empty list', () async {
    final client = MockClient(
        (request) async => http.Response('<html><body><h1>x</h1></body></html>', 200));
    final scraper = _scraper(client);
    expect(
      await scraper.videoModels(const Video(
        id: 'v',
        title: 'v',
        pageUrl: 'https://x.example.test/video/1/',
      )),
      isEmpty,
    );
    scraper.close();
  });

  test('first model page reads the photo and uses .../videos/', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        _person(image: 'https://x.example.test/contents/models/290/s1.jpg')
            .replaceAll('%CARDS%', _card.replaceAll('%ID%', 'a')),
        200,
      );
    });
    final scraper = _scraper(client);
    const model = ModelRef(
      name: 'Playwithanny',
      url: 'https://x.example.test/models/playwithanny/',
    );

    final page = await scraper.modelPage(model);

    expect(requested.single.toString(),
        'https://x.example.test/models/playwithanny/videos/');
    expect(page.profile?.name, 'Playwithanny');
    expect(page.profile?.imageUrl,
        'https://x.example.test/contents/models/290/s1.jpg');
    expect(page.videos.map((v) => v.id), hasLength(1));
    scraper.close();
  });

  test('a model without a photo has no image', () async {
    final client = MockClient((request) async =>
        http.Response(_person().replaceAll('%CARDS%', ''), 200));
    final scraper = _scraper(client);
    final page = await scraper.modelPage(const ModelRef(
      name: 'Anon',
      url: 'https://x.example.test/models/anon/',
    ));
    expect(page.profile?.imageUrl, isNull);
    expect(page.profile?.name, 'Playwithanny');
    scraper.close();
  });

  test('later pages use /videos/2/ and past the last page is empty', () async {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.path);
      if (request.url.path.endsWith('/videos/2/')) {
        return http.Response(_listing(<String>['b']), 200);
      }
      return http.Response('not found', 404);
    });
    final scraper = _scraper(client);
    const model = ModelRef(
      name: 'M',
      url: 'https://x.example.test/models/m/',
    );

    final second = await scraper.modelPage(model, page: 2);
    final third = await scraper.modelPage(model, page: 3);

    expect(requested, <String>['/models/m/videos/2/', '/models/m/videos/3/']);
    expect(second.videos, hasLength(1));
    expect(second.profile, isNull);
    expect(third.videos, isEmpty);
    scraper.close();
  });

  test('a failing first page is an error, not an empty model', () async {
    final client =
        MockClient((request) async => http.Response('not found', 404));
    final scraper = _scraper(client);
    await expectLater(
      scraper.modelPage(const ModelRef(
        name: 'M',
        url: 'https://x.example.test/models/m/',
      )),
      throwsA(isA<ScraperException>()),
    );
    scraper.close();
  });

  test('albums page lists albums with their preview pictures', () async {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.path);
      return http.Response('''
        <html><body><div class="thumbs__list">
          <div class="item thumb thumb--albums">
            <a href="https://x.example.test/albums/6078/grazi-pictures-9/" title="Goddess Grazi pictures 9">
              <div class="img-holder">
                <img class="lazyload" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
                     data-src="https://storage4.example.test/contents/albums/preview/576x760/6000/6078/preview.jpg" alt="pictures 9">
              </div>
            </a>
          </div>
          <div class="item thumb thumb--albums">
            <a href="/albums/37/playwithanny-pictures/">
              <div class="img-holder"><img data-src="/contents/albums/37.jpg" alt="Playwithanny pictures"></div>
            </a>
          </div>
        </div></body></html>''', 200);
    });
    final scraper = _scraper(client);
    const model = ModelRef(
      name: 'Playwithanny',
      url: 'https://x.example.test/models/playwithanny/',
    );

    final albums = await scraper.modelAlbums(model);

    expect(requested.single, '/models/playwithanny/albums/');
    expect(albums, hasLength(2));
    expect(albums[0].title, 'Goddess Grazi pictures 9');
    expect(albums[0].url,
        'https://x.example.test/albums/6078/grazi-pictures-9/');
    expect(albums[0].thumbnailUrl,
        'https://storage4.example.test/contents/albums/preview/576x760/6000/6078/preview.jpg');
    expect(albums[1].title, 'Playwithanny pictures');
    expect(albums[1].thumbnailUrl,
        'https://x.example.test/contents/albums/37.jpg');
    scraper.close();
  });

  test('a model without albums gives an empty list and later pages end', () async {
    final client = MockClient((request) async => request.url.path.endsWith('/albums/2/')
        ? http.Response('nope', 404)
        : http.Response('<html><body></body></html>', 200));
    final scraper = _scraper(client);
    const model = ModelRef(name: 'M', url: 'https://x.example.test/models/m/');
    expect(await scraper.modelAlbums(model), isEmpty);
    expect(await scraper.modelAlbums(model, page: 2), isEmpty);
    scraper.close();
  });

  test('album photos load chunk by chunk with the site load-more request', () async {
    final seen = <Uri>[];
    final client = MockClient((request) async {
      seen.add(request.url);
      final from = request.url.queryParameters['from'];
      if (from == null) {
        return http.Response('''
          <div class="album-view photo-holder"><div class="grid" id="albumGallery">
            <div class="item"><a href="https://x.example.test/get_image/10/aaa/sources/0/37/29944.jpg/?i-acctoken=T1" class="grid-item">
              <img src="https://storage4.example.test/contents/albums/main/200x150/0/37/29944.jpg"></a></div>
            <div class="item"><a href="https://x.example.test/get_image/10/bbb/sources/0/37/29945.jpg/?i-acctoken=T1" class="grid-item">
              <img src="data:image/gif;base64,AAAA" data-webp="https://storage4.example.test/contents/albums/main/200x150/0/37/29945.jpg"></a></div>
          </div></div>''', 200);
      }
      if (from == '2') {
        // One new picture and one repeated (token differs, file is the same).
        return http.Response('''
          <div class="item"><a href="https://x.example.test/get_image/10/aaa/sources/0/37/29944.jpg/?i-acctoken=T2" class="grid-item">
            <img src="https://storage4.example.test/contents/albums/main/200x150/0/37/29944.jpg"></a></div>
          <div class="item"><a href="https://x.example.test/get_image/10/ccc/sources/0/37/29946.jpg/?i-acctoken=T2" class="grid-item">
            <img src="https://storage4.example.test/contents/albums/main/200x150/0/37/29946.jpg"></a></div>''', 200);
      }
      return http.Response('gone', 404);
    });
    final scraper = _scraper(client);
    const album = AlbumRef(
      id: 'x.example.test/albums/37/playwithanny-pictures/',
      title: 'Playwithanny pictures',
      url: 'https://x.example.test/albums/37/playwithanny-pictures/',
    );

    final first = await scraper.albumPhotos(album);
    final second = await scraper.albumPhotos(album, chunk: 2);
    final third = await scraper.albumPhotos(album, chunk: 3);

    expect(first.map((p) => p.id), <String>['0/37/29944.jpg', '0/37/29945.jpg']);
    expect(first[0].fullUrl, contains('/sources/0/37/29944.jpg/'));
    expect(first[0].thumbUrl,
        'https://storage4.example.test/contents/albums/main/200x150/0/37/29944.jpg');
    // The placeholder data: image is skipped in favour of data-webp.
    expect(first[1].thumbUrl,
        'https://storage4.example.test/contents/albums/main/200x150/0/37/29945.jpg');
    expect(second.map((p) => p.id), <String>['0/37/29944.jpg', '0/37/29946.jpg']);
    expect(third, isEmpty);

    final more = seen[1].queryParameters;
    expect(more['mode'], 'async');
    expect(more['function'], 'get_block');
    expect(more['block_id'], 'album_view_album_view');
    expect(more['load'], 'more');
    expect(more['from'], '2');
    scraper.close();
  });
}
