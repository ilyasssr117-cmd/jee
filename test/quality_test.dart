import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watch_tube/models.dart';
import 'package:watch_tube/scraper.dart';

void main() {
  const video = Video(
    id: 'one',
    title: 'One',
    streamUrl: 'best',
    qualities: <StreamQuality>[
      StreamQuality(height: 1080, url: 'u1080'),
      StreamQuality(height: 720, url: 'u720'),
      StreamQuality(height: 480, url: 'u480'),
    ],
  );

  test('streamForQuality picks the best option not above the wish', () {
    expect(video.streamForQuality(0), 'u1080');
    expect(video.streamForQuality(1080), 'u1080');
    expect(video.streamForQuality(1000), 'u720');
    expect(video.streamForQuality(720), 'u720');
    expect(video.streamForQuality(240), 'u480');
  });

  test('Auto goes back to the best rendition after a manual pick', () {
    final lowered = video.copyWith(streamUrl: 'u480');
    expect(lowered.streamForQuality(0), 'u1080');
    expect(lowered.qualityIndexFor(720), 1);
    expect(lowered.qualityIndexFor(0), -1);
  });

  test('a single quality leaves the stream unchanged', () {
    final single = video.copyWith(
      qualities: const <StreamQuality>[StreamQuality(height: 720, url: 'u720')],
    );
    expect(single.streamForQuality(360), 'best');
  });

  test('detail page lists every labelled quality, highest first', () async {
    final client = MockClient((request) async => http.Response(
          '''
          <html><body>
            <h1>Title</h1>
            <script>
              video_url: 'https://cdn.example.test/v_720.mp4',
              video_url_text: '720p',
              video_alt_url: 'https://cdn.example.test/v_1080.mp4',
              video_alt_url_text: '1080p',
              video_alt_url2: 'https://cdn.example.test/v_480.mp4',
              video_alt_url2_text: '480p'
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
      title: 'Fallback',
      pageUrl: 'https://videos.example.test/watch/one',
    ));

    expect(resolved.streamUrl, 'https://cdn.example.test/v_1080.mp4');
    expect(resolved.qualities.map((q) => q.height), <int>[1080, 720, 480]);
    scraper.close();
  });
}
