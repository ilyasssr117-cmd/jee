import 'package:flutter/foundation.dart';

import 'models.dart';
import 'scraper.dart';

/// Widgets depend on this contract while the app uses the HTML scraper only.
abstract class VideoCatalogRepository {
  List<String> get categories;

  Future<List<Video>> getVideos({
    required int page,
    required int pageSize,
    String? category,
  });

  Future<List<Video>> searchVideos({
    required String query,
    required int page,
    required int pageSize,
  });

  Future<List<Video>> getRelated(Video video, {int limit = 6});

  Future<Video> resolveForPlayback(Video video);
}

/// Base URL used by the HTML scraper. You can override it at build/run time
/// with --dart-define=VIDEO_SOURCE_BASE_URL=https://your-source.example.
const String sourceBaseUrl = String.fromEnvironment(
  'VIDEO_SOURCE_BASE_URL',
  defaultValue: 'https://mynae.com',
);

List<String> _parseCommaSeparated(String value) => value
    .split(',')
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

final ScraperConfig _scraperConfig = ScraperConfig(
  baseUrl: sourceBaseUrl,
  homePath: const String.fromEnvironment(
    'VIDEO_HOME_PATH',
    defaultValue: '/',
  ),
  pagePathTemplate: const String.fromEnvironment(
    'VIDEO_PAGE_PATH_TEMPLATE',
    defaultValue: '/video/{page}/',
  ),
  searchPathTemplate: const String.fromEnvironment(
    'VIDEO_SEARCH_PATH_TEMPLATE',
    defaultValue: '/search/{query}/{page}/',
  ),
  categoryPathTemplate: const String.fromEnvironment(
    'VIDEO_CATEGORY_PATH_TEMPLATE',
    defaultValue: '/categories/{slug}/{page}/',
  ),
  cardSelector: const String.fromEnvironment(
    'VIDEO_CARD_SELECTOR',
    defaultValue:
        '.thumbs__list .item.thumb, .thumb-spot, article[data-video], .video-card, .video-item',
  ),
  anchorSelector: const String.fromEnvironment(
    'VIDEO_ANCHOR_SELECTOR',
    defaultValue: 'a[href]',
  ),
  imageSelector: const String.fromEnvironment(
    'VIDEO_IMAGE_SELECTOR',
    defaultValue: 'img',
  ),
  titleSelector: const String.fromEnvironment(
    'VIDEO_TITLE_SELECTOR',
    defaultValue:
        '[itemprop="name"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3',
  ),
  durationSelector: const String.fromEnvironment(
    'VIDEO_DURATION_SELECTOR',
    defaultValue: '.duration, [data-duration]',
  ),
  durationIconSelector: const String.fromEnvironment(
    'VIDEO_DURATION_ICON_SELECTOR',
    defaultValue: '.icon-duration',
  ),
  dateIconSelector: const String.fromEnvironment(
    'VIDEO_DATE_ICON_SELECTOR',
    defaultValue: '.icon-calendar',
  ),
  viewsIconSelector: const String.fromEnvironment(
    'VIDEO_VIEWS_ICON_SELECTOR',
    defaultValue: '.icon-view',
  ),
  viewsSelector: const String.fromEnvironment(
    'VIDEO_VIEWS_SELECTOR',
    defaultValue: '.views, [data-views]',
  ),
  descriptionSelector: const String.fromEnvironment(
    'VIDEO_DESCRIPTION_SELECTOR',
    defaultValue: 'meta[property="og:description"], meta[name="description"]',
  ),
  likesSelector: const String.fromEnvironment(
    'VIDEO_LIKES_SELECTOR',
    defaultValue:
        '.rating, .likes, .thumb-spot__rating, [data-rating], [data-likes]',
  ),
  videoPathPattern: const String.fromEnvironment(
    'VIDEO_PATH_PATTERN',
    defaultValue: r'/video/',
  ),
  excludePathPattern: const String.fromEnvironment(
    'VIDEO_EXCLUDE_PATH_PATTERN',
    defaultValue: r'/albums?/|/galleries/|/gallery/|/photos?/|/pictures?/',
  ),
  relatedCardSelector: const String.fromEnvironment(
    'VIDEO_RELATED_CARD_SELECTOR',
    defaultValue:
        '.related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item',
  ),
  streamUrlPattern: const String.fromEnvironment(
    'VIDEO_STREAM_URL_PATTERN',
    defaultValue: r'''(?:video_url|file|src)\s*[:=]\s*["']([^"']+)["']''',
  ),
  detailTitlePattern: const String.fromEnvironment(
    'VIDEO_DETAIL_TITLE_PATTERN',
    defaultValue: r'''(?:video_title|title)\s*[:=]\s*["']([^"']*)["']''',
  ),
  previewPattern: const String.fromEnvironment(
    'VIDEO_PREVIEW_PATTERN',
    defaultValue: r'''(?:preview_url1?|poster)\s*[:=]\s*["']([^"']+)["']''',
  ),
  categories: _parseCommaSeparated(
    const String.fromEnvironment('VIDEO_CATEGORIES', defaultValue: ''),
  ),
);

/// The only catalogue provider in this app: all pages use the HTML scraper.
final VideoCatalogRepository videoRepository = HtmlScraperVideoRepository(
  Scraper(_scraperConfig),
);

/// Adapter that keeps HTML parsing and networking outside the Flutter widgets.
class HtmlScraperVideoRepository implements VideoCatalogRepository {
  HtmlScraperVideoRepository(this.scraper);

  final Scraper scraper;

  @override
  List<String> get categories => scraper.config.categories;

  void _ensureConfigured() {
    final uri = Uri.tryParse(scraper.config.baseUrl.trim());
    final isHttp = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    final isPlaceholder = scraper.config.baseUrl
        .toLowerCase()
        .contains('your-authorized-source');

    if (!isHttp || isPlaceholder) {
      throw const ScraperException(
        'Configure sourceBaseUrl in lib/video_repository.dart or run Flutter '
        'with --dart-define=VIDEO_SOURCE_BASE_URL=https://your-authorized-source.example.',
      );
    }
  }

  @override
  Future<List<Video>> getVideos({
    required int page,
    required int pageSize,
    String? category,
  }) async {
    _ensureConfigured();
    debugPrint('[WATCH_TUBE] repository: getVideos page=$page category=$category');
    if (category != null && category.trim().isNotEmpty && category != 'All') {
      final videos = await scraper.category(category, page: page + 1);
      debugPrint('[WATCH_TUBE] repository: category returned ${videos.length} videos');
      return videos;
    }
    // The website page itself provides pagination. page 0 is its homepage;
    // page 1 and onwards use pagePathTemplate.
    final videos = await scraper.home(page: page);
    debugPrint('[WATCH_TUBE] repository: homepage returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<List<Video>> searchVideos({
    required String query,
    required int page,
    required int pageSize,
  }) async {
    _ensureConfigured();
    debugPrint('[WATCH_TUBE] repository: search query="$query" page=$page');
    final videos = await scraper.search(query, page: page + 1);
    debugPrint('[WATCH_TUBE] repository: search returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<List<Video>> getRelated(Video video, {int limit = 6}) async {
    _ensureConfigured();
    debugPrint('[WATCH_TUBE] repository: related videos for ${video.pageUrl}');
    final videos = await scraper.related(video, limit: limit);
    debugPrint('[WATCH_TUBE] repository: related returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<Video> resolveForPlayback(Video video) async {
    _ensureConfigured();
    debugPrint('[WATCH_TUBE] repository: resolving playback for ${video.pageUrl}');
    final resolved = await scraper.resolveForPlayback(video);
    debugPrint('[WATCH_TUBE] repository: stream URL resolved=${resolved.streamUrl.isNotEmpty}');
    return resolved;
  }
}
