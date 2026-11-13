import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vxtube_final/content_source.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/scraper.dart';
import 'package:vxtube_final/video_repository.dart';

void main() {
  test('switching sources uses each source-specific listing route', () async {
    final requestedUris = <Uri>[];
    final scrapers = <ContentSource, Scraper>{};

    for (final source in ContentSource.values) {
      scrapers[source] = Scraper(
        scraperConfigForSource(source),
        client: MockClient((request) async {
          requestedUris.add(request.url);
          return http.Response('<html><body></body></html>', 200);
        }),
      );
    }

    final repository = HtmlScraperVideoRepository(
      scrapers: scrapers,
      source: ContentSource.fetish,
    );

    await repository.getVideos(page: 0, pageSize: 12);
    repository.setSource(ContentSource.straight);
    await repository.getVideos(page: 0, pageSize: 12);
    repository.setSource(ContentSource.trans);
    await repository.getVideos(page: 0, pageSize: 12);

    expect(
      requestedUris,
      <Uri>[
        Uri.parse('https://x-fetish.tube/'),
        Uri.parse('https://x-x-x.tube/videos/'),
        Uri.parse('https://x-tg.tube/'),
      ],
    );
    expect(repository.source, ContentSource.trans);

    for (final scraper in scrapers.values) {
      scraper.close();
    }
  });

  test('saved pages resolve through the scraper matching their own domain',
      () async {
    final requestedUris = <Uri>[];
    final scrapers = <ContentSource, Scraper>{};

    for (final source in ContentSource.values) {
      scrapers[source] = Scraper(
        scraperConfigForSource(source),
        client: MockClient((request) async {
          requestedUris.add(request.url);
          return http.Response('<html><body></body></html>', 200);
        }),
      );
    }

    final repository = HtmlScraperVideoRepository(
      scrapers: scrapers,
      source: ContentSource.fetish,
    );
    repository.setSource(ContentSource.trans);

    await repository.getModelPage(
      const ModelRef(
        name: 'Saved model',
        url: 'https://x-x-x.tube/models/saved-model/',
      ),
    );

    expect(
      requestedUris.single,
      Uri.parse('https://x-x-x.tube/models/saved-model/'),
    );

    for (final scraper in scrapers.values) {
      scraper.close();
    }
  });
}
