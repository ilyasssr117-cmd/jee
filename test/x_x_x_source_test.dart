import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vxtube_final/content_source.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/scraper.dart';
import 'package:vxtube_final/video_repository.dart';

void main() {
  group('X-X-X source configuration', () {
    final config = scraperConfigForSource(ContentSource.straight);

    test('uses the X-X-X listing, pagination, search and model routes', () {
      expect(config.baseUrl, 'https://x-x-x.tube');
      expect(config.homeUri().path, '/videos/');
      expect(config.pageUri(1).path, '/videos/2/');
      expect(config.pageUri(2).path, '/videos/3/');
      expect(config.searchUri('Alina Rose', 1).path, '/search/alina_rose/');
      expect(config.searchUri('Alina Rose', 2).path, '/search/alina_rose/2/');

      final model = Uri.parse('https://x-x-x.tube/models/ekomomai/');
      expect(config.modelVideosUri(model, 1), model);
      expect(config.modelVideosUri(model, 2).path, '/models/ekomomai/2/');
      expect(config.videoPathPattern, r'/videos/\d+(?:/|$)');
      expect(config.cardSelector, '.thumb-holder .item.thumb');
    });


    test('uses the model profile itself as its video listing page', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async {
          expect(request.url.path, '/models/ekomomai/');
          return http.Response('''
            <html><body>
              <div class="thumb-holder">
                <div class="item thumb">
                  <a href="/videos/2008589/sample-video/"
                     title="Sample model video">
                    <img src="/contents/sample.jpg" alt="Sample model video" />
                    <div class="duration">10:24</div>
                    <div class="title">Sample model video</div>
                  </a>
                </div>
              </div>
            </body></html>
          ''', 200);
        }),
      );

      final page = await scraper.modelPage(
        const ModelRef(
          name: 'EKomoMai',
          url: 'https://x-x-x.tube/models/ekomomai/',
        ),
      );
      expect(page.videos, hasLength(1));
      expect(page.videos.single.title, 'Sample model video');
      scraper.close();
    });

    test('falls back to X-X-X search results for model albums', () async {
      final requestedPaths = <String>[];
      final scraper = Scraper(
        config,
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path == '/models/zafira-may/albums/') {
            return http.Response('not found', 404);
          }
          return http.Response('''
            <html><body>
              <div class="thumb-holder">
                <div class="item thumb">
                  <a href="/albums/76196/cezaria-a/"
                     title="Zafira May photoshoot">
                    <img src="/contents/albums/76196/preview.jpg" />
                  </a>
                </div>
              </div>
            </body></html>
          ''', 200);
        }),
      );

      final albums = await scraper.modelAlbums(
        const ModelRef(
          name: 'Zafira May',
          url: 'https://x-x-x.tube/models/zafira-may/',
        ),
      );
      expect(requestedPaths,
          <String>['/models/zafira-may/albums/', '/search/zafira_may/']);
      expect(albums, hasLength(1));
      expect(albums.single.modelName, 'Zafira May');
      scraper.close();
    });

    test('homepage pagination skips the nonexistent /videos/1/ route', () async {
      final requestedPaths = <String>[];
      final scraper = Scraper(
        config,
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
          return http.Response('<html><body></body></html>', 200);
        }),
      );

      await scraper.home(page: 0);
      await scraper.home(page: 1);

      expect(requestedPaths, <String>['/videos/', '/videos/2/']);
      scraper.close();
    });

    test('parses the supplied thumb-holder video card structure', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async {
          expect(request.url, Uri.parse('https://x-x-x.tube/videos/'));
          return http.Response('''
            <html><body>
              <section id="list_videos_videos_index">
                <div class="thumb-holder">
                  <div class="item thumb">
                    <div class="thumb-inner">
                      <a href="https://x-x-x.tube/videos/2008589/sample-video/"
                         title="Sample Video by Seth Gamble">
                        <div class="img">
                          <img loading="lazy"
                            src="/contents/videos_screenshots/2008000/2008589/566x302/3.jpg"
                            alt="Sample Video"
                            data-preview="/get_file/36/token/2008000/2008589/2008589_preview.mp4/" />
                          <div class="duration">25:56</div>
                        </div>
                        <div class="model-info">
                          <div class="name">Seth Gamble</div>
                          <div class="rating">0</div>
                        </div>
                        <div class="title">Sample Video by Seth Gamble</div>
                      </a>
                    </div>
                  </div>
                </div>
              </section>
            </body></html>
          ''', 200);
        }),
      );

      final videos = await scraper.home();
      expect(videos, hasLength(1));
      expect(videos.single.title, 'Sample Video by Seth Gamble');
      expect(videos.single.duration, '25:56');
      expect(videos.single.pageUrl,
          'https://x-x-x.tube/videos/2008589/sample-video/');
      expect(videos.single.thumbnailUrl,
          'https://x-x-x.tube/contents/videos_screenshots/2008000/2008589/566x302/3.jpg');
      expect(videos.single.previewUrl,
          'https://x-x-x.tube/get_file/36/token/2008000/2008589/2008589_preview.mp4/');
      scraper.close();
    });


    test('uses the full title attribute when search-card text is truncated', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async => http.Response('''
          <html><body>
            <div class="thumb-holder">
              <div class="item thumb">
                <a href="/videos/2009001/search-result/">
                  <div class="img">
                    <img src="/contents/search-result.jpg" alt="Thumbnail alt" />
                  </div>
                  <div class="title"
                       title="The Complete Original Search Result Title with Full Ending">
                    The Complete Original Search Result Title...
                  </div>
                  <div class="duration">18:42</div>
                </a>
              </div>
            </div>
          </body></html>
        ''', 200)),
      );

      final videos = await scraper.search('original title');
      expect(videos, hasLength(1));
      expect(
        videos.single.title,
        'The Complete Original Search Result Title with Full Ending',
      );
      scraper.close();
    });

    test('reads VideoObject contentUrl as the playable stream', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async => http.Response('''
          <html><head>
            <script type="application/ld+json">
              {
                "@context":"https://schema.org",
                "@type":"VideoObject",
                "name":"Sample Detail",
                "description":"Sample JSON-LD description",
                "thumbnailUrl":"https://x-x-x.tube/contents/videos_screenshots/2008000/2008589/preview.jpg",
                "contentUrl":"https://x-x-x.tube/get_file/36/token/2008000/2008589/2008589_720p.mp4/",
                "author": {
                  "@type":"Person",
                  "name":"Zafira May",
                  "url":"https://x-x-x.tube/models/zafira-may-mugur/"
                }
              }
            </script>
          </head><body><h1>Sample Detail</h1></body></html>
        ''', 200)),
      );

      const video = Video(
        id: 'x-x-x.tube/videos/2008589/sample-video/',
        title: 'Sample Detail',
        pageUrl: 'https://x-x-x.tube/videos/2008589/sample-video/',
      );
      final resolved = await scraper.resolveForPlayback(video);
      expect(resolved.streamUrl,
          'https://x-x-x.tube/get_file/36/token/2008000/2008589/2008589_720p.mp4/');
      expect(resolved.description, 'Sample JSON-LD description');
      expect(resolved.thumbnailUrl,
          'https://x-x-x.tube/contents/videos_screenshots/2008000/2008589/preview.jpg');
      scraper.close();
    });

    test('extracts model profiles from VideoObject.author JSON-LD', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async => http.Response('''
          <html><head>
            <script type="application/ld+json">
              {
                "@type":"VideoObject",
                "author": {
                  "@type":"Person",
                  "name":"Zafira May",
                  "url":"https://x-x-x.tube/models/zafira-may-mugur/"
                }
              }
            </script>
          </head><body></body></html>
        ''', 200)),
      );

      const video = Video(
        id: 'sample',
        title: 'Sample',
        pageUrl: 'https://x-x-x.tube/videos/2008589/sample-video/',
      );
      final models = await scraper.videoModels(video);
      expect(models, hasLength(1));
      expect(models.single.name, 'Zafira May');
      expect(models.single.url, 'https://x-x-x.tube/models/zafira-may-mugur/');
      scraper.close();
    });

    test('keeps the visible model name when JSON-LD has no author URL', () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async => http.Response('''
          <html><head>
            <script type="application/ld+json">
              {
                "@type":"VideoObject",
                "author": {"@type":"Person","name":"Zafira May"}
              }
            </script>
          </head><body></body></html>
        ''', 200)),
      );
      const video = Video(
        id: 'sample-no-author-url',
        title: 'Sample',
        pageUrl: 'https://x-x-x.tube/videos/2008589/sample-video/',
      );
      final models = await scraper.videoModels(video);
      expect(models, hasLength(1));
      expect(models.single.name, 'Zafira May');
      expect(models.single.url, 'https://x-x-x.tube/models/zafira-may/');
      scraper.close();
    });

    test('parses X-X-X album cards from the shared thumb-holder container',
        () async {
      final scraper = Scraper(
        config,
        client: MockClient((request) async {
          expect(request.url.path, '/albums/');
          return http.Response('''
            <html><body>
              <div class="thumb-holder">
                <div class="item thumb">
                  <a href="/albums/76196/cezaria-a/"
                     title="MetArt Models photoshoot">
                    <div class="img">
                      <img src="/contents/albums/76196/preview.jpg"
                           alt="MetArt Models" />
                    </div>
                  </a>
                </div>
              </div>
            </body></html>
          ''', 200);
        }),
      );

      final albums = await scraper.allAlbums();
      expect(albums, hasLength(1));
      expect(albums.single.title, 'MetArt Models photoshoot');
      expect(albums.single.url, 'https://x-x-x.tube/albums/76196/cezaria-a/');
      expect(albums.single.thumbnailUrl,
          'https://x-x-x.tube/contents/albums/76196/preview.jpg');
      scraper.close();
    });
  });
}
