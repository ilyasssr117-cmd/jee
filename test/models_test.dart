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
}
