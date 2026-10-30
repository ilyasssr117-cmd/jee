import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_tube/models.dart';
import 'package:watch_tube/scraper.dart';
import 'package:watch_tube/video_repository.dart';

void main() {
  test('app catalogue always uses the HTML scraper repository', () {
    expect(videoRepository, isA<HtmlScraperVideoRepository>());
  });

  test('homepage parses thumb-list cards and lazy-loaded artwork', () async {
    final requestedUris = <Uri>[];
    final client = MockClient((request) async {
      requestedUris.add(request.url);
      return http.Response(
        '''
        <html><body>
          <div class="thumbs__list">
            <div class="item thumb">
              <a href="/video/one/" title="Example Video">
                <img data-src="/images/one.jpg" alt="Example Video">
              </a>
              <div class="thumb-spot__data">
                <ul><li>12:34</li><li>HD</li><li>1,234 views</li></ul>
              </div>
            </div>
          </div>
        </body></html>
        ''',
        200,
      );
    });
    final scraper = Scraper(
      const ScraperConfig(baseUrl: 'https://videos.example.test'),
      client: client,
    );

    final firstPage = await scraper.home();
    final secondPage = await scraper.home(page: 1);

    expect(requestedUris[0], Uri.parse('https://videos.example.test/'));
    expect(
      requestedUris[1],
      Uri.parse('https://videos.example.test/video/1/'),
    );
    expect(firstPage, hasLength(1));
    expect(firstPage.first.title, 'Example Video');
    expect(firstPage.first.duration, '12:34');
    expect(firstPage.first.views, '1.2K views');
    expect(
      firstPage.first.pageUrl,
      'https://videos.example.test/video/one/',
    );
    expect(
      firstPage.first.thumbnailUrl,
      'https://videos.example.test/images/one.jpg',
    );
    expect(secondPage, hasLength(1));

    scraper.close();
  });

  test('detail page reads video_url and preview_url1 assignments', () async {
    final client = MockClient((request) async => http.Response(
          '''
          <html><head>
            <meta property="og:description" content="A sample description">
          </head><body>
            <h1 class="title">Detail title</h1>
            <script>
              video_title: 'Detail title',
              video_url: 'https://cdn.example.test/video.mp4?token=abc',
              preview_url1: 'https://cdn.example.test/preview.jpg'
            </script>
          </body></html>
          ''',
          200,
        ));
    final scraper = Scraper(
      const ScraperConfig(baseUrl: 'https://videos.example.test'),
      client: client,
    );

    final resolved = await scraper.resolveForPlayback(const Video(
      id: 'one',
      title: 'Fallback title',
      pageUrl: 'https://videos.example.test/watch/one',
    ));

    expect(resolved.title, 'Detail title');
    expect(
      resolved.streamUrl,
      'https://cdn.example.test/video.mp4?token=abc',
    );
    expect(
      resolved.thumbnailUrl,
      'https://cdn.example.test/preview.jpg',
    );
    expect(resolved.description, 'A sample description');
    scraper.close();
  });

  test('empty search terms do not issue a network request', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response('<html></html>', 200);
    });
    final scraper = Scraper(
      const ScraperConfig(baseUrl: 'https://videos.example.test'),
      client: client,
    );

    expect(await scraper.search('   '), isEmpty);
    expect(requestCount, 0);
    scraper.close();
  });
}
