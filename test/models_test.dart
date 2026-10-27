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

  test('album photos: page, then load-more from=1, 2, 3 until nothing is left', () async {
    final seen = <Uri>[];
    final asyncHeaders = <Map<String, String>>[];
    String tile(String hash, String file, String token, {String thumb = ''}) => '''
      <div class="item"><a href="https://x.example.test/get_image/10/$hash/sources/0/37/$file/?i-acctoken=$token" class="grid-item">
        <img src="${thumb.isEmpty ? 'https://storage4.example.test/contents/albums/main/200x150/0/37/$file' : thumb}"></a></div>''';
    final client = MockClient((request) async {
      seen.add(request.url);
      final from = request.url.queryParameters['from'];
      if (from == null) {
        // The album page: the first batch (one tile only has a lazy data-webp).
        return http.Response('''
          <div class="album-view photo-holder"><div class="grid" id="albumGallery">
            ${tile('aaa', '29944.jpg', 'T1')}
            <div class="item"><a href="https://x.example.test/get_image/10/bbb/sources/0/37/29945.jpg/?i-acctoken=T1" class="grid-item">
              <img src="data:image/gif;base64,AAAA" data-webp="https://storage4.example.test/contents/albums/main/200x150/0/37/29945.jpg"></a></div>
          </div></div>''', 200);
      }
      asyncHeaders.add(request.headers);
      switch (from) {
        case '1': // Repeats the page (new token) and adds one picture.
          return http.Response(
              '${tile('aaa', '29944.jpg', 'T2')}${tile('ccc', '29946.jpg', 'T2')}', 200);
        case '2':
          return http.Response(tile('ddd', '29947.jpg', 'T2'), 200);
        default: // No picture at all = the end.
          return http.Response('<div></div>', 200);
      }
    });
    final scraper = _scraper(client);
    const album = AlbumRef(
      id: 'x.example.test/albums/37/playwithanny-pictures/',
      title: 'Playwithanny pictures',
      url: 'https://x.example.test/albums/37/playwithanny-pictures/',
    );

    final page = await scraper.albumPhotos(album);
    final one = await scraper.albumPhotos(album, chunk: 1);
    final two = await scraper.albumPhotos(album, chunk: 2);
    final three = await scraper.albumPhotos(album, chunk: 3);

    expect(page.map((p) => p.id), <String>['0/37/29944.jpg', '0/37/29945.jpg']);
    expect(page[1].thumbUrl,
        'https://storage4.example.test/contents/albums/main/200x150/0/37/29945.jpg');
    expect(one.map((p) => p.id), <String>['0/37/29944.jpg', '0/37/29946.jpg']);
    expect(two.map((p) => p.id), <String>['0/37/29947.jpg']);
    expect(three, isEmpty);

    final first = seen[1].queryParameters;
    expect(first['mode'], 'async');
    expect(first['function'], 'get_block');
    expect(first['block_id'], 'album_view_album_view');
    expect(first['load'], 'more');
    expect(first['from'], '1');
    expect(seen.map((u) => u.queryParameters['from']),
        <String?>[null, '1', '2', '3']);
    // Sent like the site's own script does.
    expect(asyncHeaders.first['X-Requested-With'], 'XMLHttpRequest');
    expect(asyncHeaders.first['Referer'], album.url);
    scraper.close();
  });

  test('video search can be sorted with ?by=post_date and ?by=duration', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response('<html><body></body></html>', 200);
    });
    final scraper = _scraper(client);

    await scraper.search('Playwithanny', sortBy: 'post_date');
    await scraper.search('Playwithanny', sortBy: 'duration', page: 2);
    await scraper.search('Playwithanny');

    expect(requested[0].path, '/search/Playwithanny/');
    expect(requested[0].queryParameters, <String, String>{'by': 'post_date'});
    expect(requested[1].path, '/search/Playwithanny/2/');
    expect(requested[1].queryParameters, <String, String>{'by': 'duration'});
    expect(requested[2].queryParameters, isEmpty);
    scraper.close();
  });

  test('model photo: found in og:image or in broken JSON-LD, absent for some', () async {
    const model = ModelRef(name: 'M', url: 'https://x.example.test/models/m/');

    Future<ModelProfile?> profileOf(String html) async {
      final scraper = _scraper(MockClient((r) async => http.Response(html, 200)));
      final page = await scraper.modelPage(model);
      scraper.close();
      return page.profile;
    }

    expect(
      (await profileOf('<html><head><meta property="og:image" content="/contents/m.jpg"></head></html>'))
          ?.imageUrl,
      'https://x.example.test/contents/m.jpg',
    );
    // Trailing comma = invalid JSON: the photo is still read from the text.
    expect(
      (await profileOf('''<html><head><script type="application/ld+json">
        { "@type": "Person", "name": "M", "image": "https:\\/\\/x.example.test\\/contents\\/models\\/290\\/s1.jpg", }
        </script></head></html>'''))
          ?.imageUrl,
      'https://x.example.test/contents/models/290/s1.jpg',
    );
    expect((await profileOf('<html><head></head></html>'))?.imageUrl, isNull);
    // The site logo in og:image is not the model's photo.
    expect(
      (await profileOf('<html><head><meta property="og:image" content="https://x.example.test/static/images/logo.png"></head></html>'))
          ?.imageUrl,
      isNull,
    );
  });

  test('models & albums search finds the model by name and its albums', () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/models/playwithanny/videos/') {
        return http.Response(_person(image: 'https://x.example.test/contents/models/290/s1.jpg')
            .replaceAll('%CARDS%', ''), 200);
      }
      if (path == '/search/Playwithanny/') {
        return http.Response('''
          <html><body>
            <a href="/models/other-model/">Other Model</a>
            <div class="item thumb thumb--albums"><a href="/albums/9/loose-album/" title="Loose album">
              <img data-src="/c/9.jpg"></a></div>
          </body></html>''', 200);
      }
      if (path == '/models/playwithanny/albums/') {
        return http.Response('''
          <div class="item thumb thumb--albums"><a href="/albums/37/playwithanny-pictures/" title="Playwithanny pictures">
            <img data-src="/c/37.jpg"></a></div>''', 200);
      }
      return http.Response('nope', 404);
    });
    final scraper = _scraper(client);

    final result = await scraper.searchPeople('Playwithanny');

    expect(result.models.map((m) => m.name), <String>['Playwithanny', 'Other Model']);
    expect(result.models.first.imageUrl,
        'https://x.example.test/contents/models/290/s1.jpg');
    expect(result.albums.map((a) => a.title),
        containsAll(<String>['Loose album', 'Playwithanny pictures']));
    expect(
      result.albums.firstWhere((a) => a.title == 'Playwithanny pictures').modelName,
      'Playwithanny',
    );
    scraper.close();
  });
}
