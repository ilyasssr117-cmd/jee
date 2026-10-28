import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'request_cache.dart';
import 'scraper.dart';
import 'stream_resolver.dart';

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
    String? sortBy,
  });

  Future<PeopleSearchResult> searchPeople(String query);

  Future<ModelProfile> getModelProfile(ModelRef model);

  Future<List<Video>> getRelated(Video video, {int limit = 6});

  Future<Video> resolveForPlayback(Video video, {bool refresh = false});

  void clearPlaybackCaches();

  Future<List<ModelRef>> getVideoModels(Video video);

  Future<ModelPageResult> getModelPage(ModelRef model, {int page = 1});

  Future<List<AlbumRef>> getModelAlbums(ModelRef model, {int page = 1});

  Future<List<AlbumPhoto>> getAlbumPhotos(AlbumRef album, {int chunk = 0});

  Future<String> getPlaybackCookieHeader({
    required Uri streamUri,
    String? pageUrl,
    required String userAgent,
    bool refresh = false,
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

  final TtlCache<Video> _playable = TtlCache<Video>(
    ttl: const Duration(minutes: 8),
    maxEntries: 40,
  );

  static const Duration _cookieTtl = Duration(minutes: 10);
  final Map<String, DateTime> _cookieVisits = <String, DateTime>{};
  final Map<String, Future<void>> _cookieRunning = <String, Future<void>>{};

  @override
  void clearPlaybackCaches() {
    _playable.clear();
    _cookieVisits.clear();
    _cookieRunning.clear();
    clearFinalStreamUris();
  }

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
    if (category != null && category.trim().isNotEmpty && category != 'All') {
      return scraper.category(category, page: page + 1);
    }
    return scraper.home(page: page);
  }

  @override
  Future<List<Video>> searchVideos({
    required String query,
    required int page,
    required int pageSize,
    String? sortBy,
  }) async {
    _ensureConfigured();
    return scraper.search(query, page: page + 1, sortBy: sortBy);
  }

  @override
  Future<List<Video>> getRelated(Video video, {int limit = 6}) async {
    _ensureConfigured();
    return scraper.related(video, limit: limit);
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
    return scraper.modelPage(model, page: page);
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
  Future<Video> resolveForPlayback(Video video, {bool refresh = false}) async {
    _ensureConfigured();
    final given = video.streamUrl.trim();
    if (given.isNotEmpty && given != video.previewUrl.trim()) return video;
    final resolved = await _playable.fetch(
      video.id,
      () => scraper.resolveForPlayback(
        video.copyWith(streamUrl: ''),
        fresh: refresh,
      ),
      force: refresh,
    );
    return video.copyWith(
      title: resolved.title,
      streamUrl: resolved.streamUrl,
      description: resolved.description,
      thumbnailUrl: resolved.thumbnailUrl,
      pageUrl: resolved.pageUrl,
    );
  }

  @override
  Future<String> getPlaybackCookieHeader({
    required Uri streamUri,
    String? pageUrl,
    required String userAgent,
    bool refresh = false,
  }) async {
    _ensureConfigured();
    final configuredUri = Uri.parse(scraper.config.baseUrl.trim());
    final configuredRoot = configuredUri.resolve('/');
    final parsedPage = Uri.tryParse(pageUrl?.trim() ?? '');
    final validPage = parsedPage != null &&
        (parsedPage.scheme == 'http' || parsedPage.scheme == 'https') &&
        parsedPage.host.isNotEmpty &&
        _sameConfiguredSite(parsedPage.host, configuredUri.host);

    await _visitForCookies(configuredRoot, userAgent, refresh);
    if (validPage && parsedPage.toString() != configuredRoot.toString()) {
      await _visitForCookies(parsedPage, userAgent, refresh);
    }

    return _cookieHeaderForUri(streamUri);
  }

  Future<void> _visitForCookies(Uri uri, String userAgent, bool refresh) {
    final key = uri.toString();
    if (!refresh) {
      final last = _cookieVisits[key];
      if (last != null && DateTime.now().difference(last) < _cookieTtl) {
        return Future<void>.value();
      }
      final running = _cookieRunning[key];
      if (running != null) return running;
    }
    late final Future<void> task;
    task = _fetchCookieResponse(uri, userAgent).then((ok) {
      if (ok) _cookieVisits[key] = DateTime.now();
    }).whenComplete(() {
      if (identical(_cookieRunning[key], task)) _cookieRunning.remove(key);
    });
    _cookieRunning[key] = task;
    return task;
  }

  Future<bool> _fetchCookieResponse(Uri initialUri, String userAgent) async {
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
      return true;
    } catch (error) {
      debugPrint('[FLOW] Cookie response fetch failed (${error.runtimeType}).');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _storeCookie(Cookie cookie, Uri responseUri) {
    final rawDomain = cookie.domain?.trim().toLowerCase();
    final hostOnly = rawDomain == null || rawDomain.isEmpty;
    final domain = rawDomain == null || rawDomain.isEmpty
        ? responseUri.host.toLowerCase()
        : rawDomain.replaceFirst(RegExp(r'^\.'), '');
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
