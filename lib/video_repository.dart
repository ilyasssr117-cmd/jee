

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'scraper.dart';

abstract class VideoCatalogRepository {
  List<String> get categories;

  Future<List<Video>> getVideos({
    required int page,
    required int pageSize,
    String? category,
  });

  /// [sortBy]: `post_date` (newest) or `duration` (longest); null = relevance.
  Future<List<Video>> searchVideos({
    required String query,
    required int page,
    required int pageSize,
    String? sortBy,
  });

  /// Models and albums matching [query] (the "Models & Albums" search).
  Future<PeopleSearchResult> searchPeople(String query);

  /// Name and photo of a model.
  Future<ModelProfile> getModelProfile(ModelRef model);

  Future<List<Video>> getRelated(Video video, {int limit = 6});

  Future<Video> resolveForPlayback(Video video);

  /// The models / channel that published [video] (empty when unknown).
  Future<List<ModelRef>> getVideoModels(Video video);

  /// One page (1-based) of [model]'s videos. Empty after the last page.
  Future<ModelPageResult> getModelPage(ModelRef model, {int page = 1});

  /// One page (1-based) of [model]'s photo albums. Empty after the last page.
  Future<List<AlbumRef>> getModelAlbums(ModelRef model, {int page = 1});

  /// One chunk of an album's photos: 0 = the album page, N >= 1 = the site's
  /// "load more" request `from=N`. Empty after the last chunk.
  Future<List<AlbumPhoto>> getAlbumPhotos(AlbumRef album, {int chunk = 0});

  Future<String> getPlaybackCookieHeader({
    required Uri streamUri,
    String? pageUrl,
    required String userAgent,
  });
}

const String sourceBaseUrl = String.fromEnvironment(
  'VIDEO_SOURCE_BASE_URL',
  defaultValue: 'https://x-fetish.tube',
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

final VideoCatalogRepository videoRepository = HtmlScraperVideoRepository(
  Scraper(_scraperConfig),
);

class HtmlScraperVideoRepository implements VideoCatalogRepository {
  HtmlScraperVideoRepository(this.scraper);

  final Scraper scraper;
  final Map<String, _RepositoryCookie> _cookieJar =
      <String, _RepositoryCookie>{};

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
    debugPrint('[FLOW] repository: getVideos page=$page category=$category');
    if (category != null && category.trim().isNotEmpty && category != 'All') {
      final videos = await scraper.category(category, page: page + 1);
      debugPrint('[FLOW] repository: category returned ${videos.length} videos');
      return videos;
    }
    final videos = await scraper.home(page: page);
    debugPrint('[FLOW] repository: homepage returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<List<Video>> searchVideos({
    required String query,
    required int page,
    required int pageSize,
    String? sortBy,
  }) async {
    _ensureConfigured();
    debugPrint('[FLOW] repository: search query="$query" page=$page sort=$sortBy');
    final videos = await scraper.search(query, page: page + 1, sortBy: sortBy);
    debugPrint('[FLOW] repository: search returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<List<Video>> getRelated(Video video, {int limit = 6}) async {
    _ensureConfigured();
    debugPrint('[FLOW] repository: related videos for video=${video.id}');
    final videos = await scraper.related(video, limit: limit);
    debugPrint('[FLOW] repository: related returned ${videos.length} videos');
    return videos;
  }

  @override
  Future<PeopleSearchResult> searchPeople(String query) async {
    _ensureConfigured();
    return scraper.searchPeople(query);
  }

  @override
  Future<ModelProfile> getModelProfile(ModelRef model) async {
    _ensureConfigured();
    return scraper.modelProfile(model);
  }

  @override
  Future<List<ModelRef>> getVideoModels(Video video) async {
    _ensureConfigured();
    return scraper.videoModels(video);
  }

  @override
  Future<ModelPageResult> getModelPage(ModelRef model, {int page = 1}) async {
    _ensureConfigured();
    debugPrint('[FLOW] repository: model ${model.name} page=$page');
    final result = await scraper.modelPage(model, page: page);
    debugPrint('[FLOW] repository: model page returned ${result.videos.length} videos');
    return result;
  }

  @override
  Future<List<AlbumRef>> getModelAlbums(ModelRef model, {int page = 1}) async {
    _ensureConfigured();
    return scraper.modelAlbums(model, page: page);
  }

  @override
  Future<List<AlbumPhoto>> getAlbumPhotos(AlbumRef album, {int chunk = 0}) async {
    _ensureConfigured();
    return scraper.albumPhotos(album, chunk: chunk);
  }

  @override
  Future<Video> resolveForPlayback(Video video) async {
    _ensureConfigured();
    debugPrint('[FLOW] repository: resolving playback for video=${video.id}');
    final resolved = await scraper.resolveForPlayback(video);
    debugPrint('[FLOW] repository: stream URL resolved=${resolved.streamUrl.isNotEmpty}');
    return resolved;
  }

  @override
  Future<String> getPlaybackCookieHeader({
    required Uri streamUri,
    String? pageUrl,
    required String userAgent,
  }) async {
    _ensureConfigured();
    final configuredUri = Uri.parse(scraper.config.baseUrl.trim());
    final configuredRoot = configuredUri.resolve('/');
    final parsedPage = Uri.tryParse(pageUrl?.trim() ?? '');
    final validPage = parsedPage != null &&
        (parsedPage.scheme == 'http' || parsedPage.scheme == 'https') &&
        parsedPage.host.isNotEmpty &&
        _sameConfiguredSite(parsedPage.host, configuredUri.host);

    await _fetchCookieResponse(configuredRoot, userAgent);
    if (validPage && parsedPage != null && parsedPage.toString() != configuredRoot.toString()) {
      await _fetchCookieResponse(parsedPage, userAgent);
    }

    return _cookieHeaderForUri(streamUri);
  }

  Future<void> _fetchCookieResponse(Uri initialUri, String userAgent) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    var currentUri = initialUri;

    try {
      for (var redirectCount = 0; redirectCount <= 5; redirectCount++) {
        final request = await client
            .getUrl(currentUri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');

        final existingCookies = _cookieHeaderForUri(currentUri);
        if (existingCookies.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, existingCookies);
        }

        final response = await request
            .close()
            .timeout(const Duration(seconds: 15));

        for (final cookie in response.cookies) {
          _storeCookie(cookie, currentUri);
        }

        final location = response.headers.value(HttpHeaders.locationHeader);
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null &&
            redirectCount < 5) {
          await response.drain<void>().timeout(const Duration(seconds: 10));
          final nextUri = currentUri.resolve(location);
          if ((nextUri.scheme != 'http' && nextUri.scheme != 'https') ||
              nextUri.host.isEmpty) {
            break;
          }
          currentUri = nextUri;
          continue;
        }

        await response.drain<void>().timeout(const Duration(seconds: 10));
        break;
      }
    } catch (error) {
      debugPrint('[FLOW] Cookie response fetch failed (${error.runtimeType}).');
    } finally {
      client.close(force: true);
    }
  }

  void _storeCookie(Cookie cookie, Uri responseUri) {
    final rawDomain = cookie.domain?.trim().toLowerCase();
    final hostOnly = rawDomain == null || rawDomain.isEmpty;
    final domain = hostOnly
        ? responseUri.host.toLowerCase()
        : rawDomain!.replaceFirst(RegExp(r'^\.'), '');
    final responseHost = responseUri.host.toLowerCase();

    if (domain.isEmpty ||
        !(responseHost == domain || responseHost.endsWith('.$domain'))) {
      return;
    }

    final path = cookie.path != null && cookie.path!.startsWith('/')
        ? cookie.path!
        : _defaultCookiePath(responseUri.path);
    final key = '$domain|$path|${cookie.name}';
    final now = DateTime.now();

    if ((cookie.maxAge != null && cookie.maxAge! <= 0) ||
        (cookie.expires != null && !cookie.expires!.isAfter(now))) {
      _cookieJar.remove(key);
      return;
    }

    _cookieJar[key] = _RepositoryCookie(
      name: cookie.name,
      value: cookie.value,
      domain: domain,
      path: path,
      hostOnly: hostOnly,
      secure: cookie.secure,
      expires: cookie.expires,
      maxAge: cookie.maxAge,
      receivedAt: now,
    );
  }

  String _cookieHeaderForUri(Uri uri) {
    final now = DateTime.now();
    _cookieJar.removeWhere((_, cookie) => cookie.isExpired(now));
    final matching = _cookieJar.values
        .where((cookie) => cookie.matches(uri, now))
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  static bool _sameConfiguredSite(String host, String configuredHost) {
    String normalize(String value) => value.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final candidate = normalize(host);
    final configured = normalize(configuredHost);
    return candidate == configured || candidate.endsWith('.$configured');
  }

  static String _defaultCookiePath(String requestPath) {
    if (requestPath.isEmpty || !requestPath.startsWith('/') || requestPath == '/') {
      return '/';
    }
    final lastSlash = requestPath.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return requestPath.substring(0, lastSlash);
  }
}

class _RepositoryCookie {
  const _RepositoryCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.hostOnly,
    required this.secure,
    required this.expires,
    required this.maxAge,
    required this.receivedAt,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool hostOnly;
  final bool secure;
  final DateTime? expires;
  final int? maxAge;
  final DateTime receivedAt;

  bool isExpired(DateTime now) {
    if (expires != null && !expires!.isAfter(now)) return true;
    if (maxAge != null &&
        !receivedAt.add(Duration(seconds: maxAge!)).isAfter(now)) {
      return true;
    }
    return false;
  }

  bool matches(Uri uri, DateTime now) {
    if (isExpired(now)) return false;
    if (secure && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    final domainMatches = hostOnly
        ? host == domain
        : host == domain || host.endsWith('.$domain');
    if (!domainMatches) return false;
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath == path ||
        (requestPath.startsWith(path) &&
            (path.endsWith('/') ||
                (requestPath.length > path.length &&
                    requestPath[path.length] == '/')));
  }
}
