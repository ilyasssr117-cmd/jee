import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'request_cache.dart';

/// Decodes an HTTP HTML response using its declared charset when supported.
/// Unsupported declarations safely fall back to UTF-8 with replacement chars;
/// interpreting arbitrary bytes as Unicode code points corrupts non-UTF-8 text.
String decodeHtmlResponseBytes(Uint8List bytes, String? contentType) {
  final match = RegExp(
    r'''charset\s*=\s*[\"']?([^;\s\"']+)''',
    caseSensitive: false,
  ).firstMatch(contentType ?? '');
  final charset = match?.group(1)?.trim().toLowerCase();

  if (charset == 'windows-1252' ||
      charset == 'cp1252' ||
      charset == 'x-cp1252') {
    const windows1252 = <int>[
      0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
      0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
      0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ];
    final codeUnits = <int>[];
    for (final byte in bytes) {
      codeUnits.add(byte >= 0x80 && byte <= 0x9F
          ? windows1252[byte - 0x80]
          : byte);
    }
    return String.fromCharCodes(codeUnits);
  }

  final encoding = charset == null || charset.isEmpty
      ? utf8
      : Encoding.getByName(charset) ?? utf8;
  return encoding == utf8
      ? utf8.decode(bytes, allowMalformed: true)
      : encoding.decode(bytes);
}

class ScraperConfig {
  const ScraperConfig({
    required this.baseUrl,
    this.homePath = '/',
    this.pagePathTemplate = '/video/{page}/',
    this.pagePathPageOffset = 0,
    this.searchPathTemplate = '/search/{query}/{page}/',
    this.searchSpacesAsUnderscores = false,
    this.modelVideosPathTemplate = 'videos/{page}/',
    this.modelVideosFirstPageUsesZero = false,
    this.categoryPathTemplate = '/categories/{slug}/{page}/',
    this.cardSelector = '.thumbs__list .item.thumb, .thumb-spot, article[data-video], .video-card, .video-item',
    this.anchorSelector = 'a[href]',
    this.imageSelector = 'img',
    this.titleSelector = '[itemprop="name"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3',
    this.durationSelector = '.duration, [data-duration]',
    this.viewsSelector = '.views, [data-views]',
    this.durationIconSelector = '.icon-duration',
    this.dateIconSelector = '.icon-calendar',
    this.viewsIconSelector = '.icon-view',
    this.descriptionSelector =
        'meta[property="og:description"], meta[name="description"]',
    this.likesSelector =
        '.rating, .likes, .thumb-spot__rating, [data-rating], [data-likes]',
    this.videoPathPattern = r'/video/',
    this.excludePathPattern =
        r'/albums?/|/galleries/|/gallery/|/photos?/|/pictures?/',
    this.relatedCardSelector = '.related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item',
    this.streamUrlPattern =
        r'''(?:video_url|file|src)\s*[:=]\s*["']([^"']+)["']''',
    this.detailTitlePattern =
        r'''(?:video_title|title)\s*[:=]\s*["']([^"']*)["']''',
    this.previewPattern =
        r'''(?:preview_url1?|poster)\s*[:=]\s*["']([^"']+)["']''',
    this.userAgent =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
        'Mobile/15E148 Safari/604.1',
    this.timeout = const Duration(seconds: 28),
    this.categories = const <String>[],
  });

  final String baseUrl;
  final String homePath;
  final String pagePathTemplate;
  final int pagePathPageOffset;
  final String searchPathTemplate;
  final bool searchSpacesAsUnderscores;
  final String modelVideosPathTemplate;
  final bool modelVideosFirstPageUsesZero;
  final String categoryPathTemplate;
  final String cardSelector;
  final String anchorSelector;
  final String imageSelector;
  final String titleSelector;
  final String durationSelector;
  final String viewsSelector;
  final String durationIconSelector;
  final String dateIconSelector;
  final String viewsIconSelector;
  final String descriptionSelector;
  final String likesSelector;

  final String videoPathPattern;

  final String excludePathPattern;
  final String relatedCardSelector;
  final String streamUrlPattern;
  final String detailTitlePattern;
  final String previewPattern;
  final String userAgent;
  final Duration timeout;
  final List<String> categories;

  Uri get baseUri => Uri.parse(baseUrl);

  Uri homeUri() => baseUri.resolve(homePath);

  Uri pageUri(int page) {
    final safePage = page < 1 ? 1 : page;
    return baseUri.resolve(
      pagePathTemplate.replaceAll(
        '{page}',
        (safePage + pagePathPageOffset).toString(),
      ),
    );
  }

  Uri searchUri(String query, int page) {
    final safePage = page < 1 ? 1 : page;
    var template = searchPathTemplate;
    if (safePage == 1 && template.contains('/{page}/')) {
      template = template.replaceFirst('/{page}/', '/');
    }
    final normalizedQuery = searchSpacesAsUnderscores
        ? query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_')
        : query.trim();
    return baseUri.resolve(
      template
          .replaceAll('{query}', Uri.encodeComponent(normalizedQuery))
          .replaceAll('{page}', safePage.toString()),
    );
  }

  Uri categoryUri(String slug, int page) {
    final safePage = page < 1 ? 1 : page;
    var template = categoryPathTemplate;
    if (safePage == 1 && template.contains('/{page}/')) {
      template = template.replaceFirst('/{page}/', '/');
    }
    return baseUri.resolve(
      template
          .replaceAll('{slug}', Uri.encodeComponent(_slugify(slug)))
          .replaceAll('{page}', safePage.toString()),
    );
  }

  /// Resolves a model's video-listing page. Sources may list videos directly
  /// at `/models/<slug>/` or under a nested `/videos/` route.
  Uri modelVideosUri(Uri modelBaseUri, int page) {
    final safePage = page < 1 ? 1 : page;
    var template = modelVideosPathTemplate;
    if (safePage == 1 && modelVideosFirstPageUsesZero) {
      template = template.replaceAll('{page}', '0');
    } else if (safePage == 1) {
      template = template
          .replaceFirst('/{page}/', '/')
          .replaceFirst('{page}/', '');
    } else {
      template = template.replaceAll('{page}', safePage.toString());
    }
    return modelBaseUri.resolve(template);
  }

  static String _slugify(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');
}

class ScraperException implements Exception {
  const ScraperException(
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.retryAfter,
  });

  final String message;
  final int? statusCode;
  final bool retryable;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class Scraper {
  Scraper(this.config, {http.Client? client})
    : _client = client ?? http.Client();

  final ScraperConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
    'User-Agent': config.userAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': '${config.baseUri}/',
  };

  final TtlCache<String> _detailPages = TtlCache<String>(
    ttl: const Duration(seconds: 90),
    maxEntries: 4,
  );

  final TtlCache<Map<String, String>> _modelDirectoryImages =
      TtlCache<Map<String, String>>(
    ttl: const Duration(minutes: 30),
    maxEntries: 1,
  );

  final TtlCache<ModelCatalogSummary> _modelSummaryCache =
      TtlCache<ModelCatalogSummary>(
    ttl: const Duration(minutes: 20),
    maxEntries: 80,
  );

  Future<String> _getDetailPage(Uri uri, {bool fresh = false}) =>
      _detailPages.fetch(uri.toString(), () => _get(uri), force: fresh);

  Future<String> _get(Uri uri, {Map<String, String>? extraHeaders}) async {
    if (!_isAllowedCatalogUri(uri)) {
      throw const ScraperException('The source returned an unsafe page link.');
    }

    ScraperException? lastError;
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await _getOnce(uri, extraHeaders);
      } on ScraperException catch (error) {
        final status = error.statusCode;
        final transient =
            error.retryable ||
            status == 408 ||
            status == 425 ||
            status == 429 ||
            (status != null && status >= 500 && status <= 599);
        if (!transient || attempt == maxAttempts - 1) rethrow;
        lastError = error;
        final requestedDelay = error.retryAfter;
        final backoff = Duration(milliseconds: 450 * (1 << attempt));
        final delay = requestedDelay == null
            ? backoff
            : (requestedDelay > const Duration(seconds: 6)
                  ? const Duration(seconds: 6)
                  : requestedDelay);
        // Respect Retry-After while keeping a strict upper bound on waits.
        await Future<void>.delayed(delay);
      }
    }
    throw lastError ?? const ScraperException('The source could not be read.');
  }

  Duration? _retryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds.clamp(0, 6).toInt());
    }
    final date =
        DateTime.tryParse(value.trim()) ??
        (() {
          try {
            return HttpDate.parse(value.trim());
          } catch (_) {
            return null;
          }
        })();
    if (date == null) return null;
    final remaining = date.difference(DateTime.now());
    if (remaining.isNegative) return Duration.zero;
    return remaining > const Duration(seconds: 6)
        ? const Duration(seconds: 6)
        : remaining;
  }

  bool _isAllowedCatalogUri(Uri uri) {
    final base = config.baseUri;
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        (base.scheme == 'https' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    String normalize(String host) =>
        host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final host = normalize(uri.host);
    final source = normalize(base.host);
    if (source.isEmpty) return false;
    return host == source || host.endsWith('.$source');
  }

  Future<String> _getOnce(Uri uri, Map<String, String>? extraHeaders) async {
    try {
      var current = uri;
      final requestHeaders = <String, String>{..._headers, ...?extraHeaders};
      const redirectCodes = <int>{301, 302, 303, 307, 308};
      const maxRedirects = 5;
      const maxPageBytes = 8 * 1024 * 1024;

      for (var hop = 0; hop <= maxRedirects; hop++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers.addAll(requestHeaders);
        final response = await _client.send(request).timeout(config.timeout);

        final location = response.headers['location'];
        if (redirectCodes.contains(response.statusCode) &&
            location != null &&
            location.isNotEmpty) {
          await response.stream.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          final next = current.resolve(location);
          if (!_isAllowedCatalogUri(next)) {
            throw const ScraperException(
              'The source redirected to an untrusted page.',
            );
          }
          if (next.origin != current.origin) {
            requestHeaders.removeWhere(
              (name, _) => const <String>{
                'cookie',
                'authorization',
                'proxy-authorization',
                'referer',
              }.contains(name.toLowerCase()),
            );
          }
          current = next;
          continue;
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          throw ScraperException(
            'Source request failed with HTTP ${response.statusCode}.',
            statusCode: response.statusCode,
            retryAfter: _retryAfter(response.headers['retry-after']),
          );
        }
        if (response.contentLength != null &&
            response.contentLength! > maxPageBytes) {
          await response.stream.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          throw const ScraperException('The source page is too large.');
        }

        final bodyBuilder = BytesBuilder(copy: false);
        var received = 0;
        await for (final chunk in response.stream.timeout(config.timeout)) {
          received += chunk.length;
          if (received > maxPageBytes) {
            throw const ScraperException('The source page is too large.');
          }
          bodyBuilder.add(chunk);
        }
        final bodyBytes = bodyBuilder.takeBytes();
        final contentType = response.headers['content-type'];
        final body = decodeHtmlResponseBytes(bodyBytes, contentType);
        if (body.trim().isEmpty) {
          throw const ScraperException('The source returned an empty page.');
        }
        return body;
      }
      throw const ScraperException('The source redirected too many times.');
    } on ScraperException {
      rethrow;
    } on Exception catch (error) {
      debugPrint(
        '[SCRAPER] Request failed for ${uri.origin} (${error.runtimeType}).',
      );
      throw const ScraperException(
        'Could not reach the video source.',
        retryable: true,
      );
    }
  }

  Future<List<Video>> home({int page = 0}) {
    return list(page == 0 ? config.homeUri() : config.pageUri(page));
  }

  Future<List<Video>> search(String query, {int page = 1, String? sortBy}) {
    if (query.trim().isEmpty) return Future.value(const <Video>[]);
    var uri = config.searchUri(query, page);
    if (sortBy != null && sortBy.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{...uri.queryParameters, 'by': sortBy},
      );
    }
    return list(uri);
  }

  Future<List<Video>> category(String slug, {int page = 1}) {
    return list(config.categoryUri(slug, page));
  }

  Future<List<Video>> list(
    Uri uri, {
    bool related = false,
    bool fresh = false,
  }) async {
    final body = related
        ? await _getDetailPage(uri, fresh: fresh)
        : await _get(uri);
    final job = (
      config: config,
      body: body,
      uri: uri,
      selector: related ? config.relatedCardSelector : config.cardSelector,
    );
    return _runInBackground(_parseListJob, job);
  }

  List<Video> _videosFrom(dom.Document document, Uri uri, String selector) {
    if (selector.trim().isEmpty) return const <Video>[];

    final videos = <Video>[];
    final seen = <String>{};
    final cards = document.querySelectorAll(selector);
    for (final element in cards) {
      try {
        final video = _parseCard(element, uri);
        if (video == null || video.title.isEmpty || !seen.add(video.id)) {
          continue;
        }
        videos.add(video);
      } catch (error) {
        debugPrint(
          '[SCRAPER] Skipped an invalid video card (${error.runtimeType}).',
        );
      }
    }
    return videos;
  }

  Uri? _modelBase(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2 || segments.first.toLowerCase() != 'models') {
      return null;
    }
    // Construct a fresh URI rather than replacing query/fragment with empty
    // strings (which serializes as a spurious trailing ?#).
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/models/${segments[1]}/',
    );
  }

  Future<List<ModelRef>> videoModels(
    Video video, {
    bool fresh = false,
  }) async {
    final pageUrl = video.pageUrl;
    if (pageUrl == null || pageUrl.trim().isEmpty) return const <ModelRef>[];

    final uri = config.baseUri.resolve(pageUrl);
    final document = html.parse(await _getDetailPage(uri, fresh: fresh));
    final models = <ModelRef>[];
    final modelIndexByUrl = <String, int>{};
    final modelNamePriorityByUrl = <String, int>{};
    final isXxxSource = config.searchSpacesAsUnderscores;

    bool isGenericModelLabel(String value) {
      final normalized = _collapse(value)
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      return const <String>{
        'model',
        'models',
        'view model',
        'view models',
        'view profile',
        'model profile',
        'profile',
      }.contains(normalized);
    }

    String modelNameFromSlug(Uri base) {
      final segments = base.pathSegments.where((part) => part.isNotEmpty);
      if (segments.length < 2) return '';
      final slug = segments.elementAt(1);
      return slug
          .replaceAll(RegExp(r'[-_]+'), ' ')
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
          .join(' ');
    }

    void addModel(
      String? rawUrl,
      String? rawName, {
      bool fromStructuredData = false,
    }) {
      var name = _collapse(rawName ?? '');
      final genericName = isGenericModelLabel(name);
      final target = _resolveHttp(rawUrl, uri);
      var base = target == null ? null : _modelBase(target);

      // X-X-X may expose a generic navigation label such as "Models" or
      // "View Model". Do not manufacture /models/models/ from that label.
      // If the link identifies a real profile, derive a temporary display name
      // from its slug; VideoObject.author below will replace it with the real
      // person name when available.
      if (base == null && isXxxSource && name.isNotEmpty && !genericName) {
        final slug = name
            .toLowerCase()
            .replaceAll('&', ' and ')
            .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), '');
        if (slug.isNotEmpty) base = config.baseUri.resolve('models/$slug/');
      }
      if (base == null) return;

      final key = base.toString();
      final usedSlugFallback = name.isEmpty || genericName;
      if (usedSlugFallback) name = modelNameFromSlug(base);
      if (name.isEmpty) return;

      // Structured VideoObject.author data is the authoritative source of
      // the model's name. It must be allowed to replace generic link labels
      // (or slug-derived labels) already found for the same profile URL.
      final priority = fromStructuredData && !isGenericModelLabel(name)
          ? 3
          : usedSlugFallback
              ? 1
              : 2;
      final existingIndex = modelIndexByUrl[key];
      if (existingIndex != null) {
        if (priority > (modelNamePriorityByUrl[key] ?? 0)) {
          models[existingIndex] = ModelRef(name: name, url: key);
          modelNamePriorityByUrl[key] = priority;
        }
        return;
      }

      modelIndexByUrl[key] = models.length;
      modelNamePriorityByUrl[key] = priority;
      models.add(ModelRef(name: name, url: key));
    }

    // Prefer explicit model links where the source provides them.
    var anchors = document.querySelectorAll('.media-models a[href]');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('.media-info a[href*="/models/"]');
    }
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('a[href*="/models/"]');
    }
    for (final anchor in anchors) {
      addModel(
        anchor.attributes['href'],
        anchor.text.trim().isNotEmpty
            ? anchor.text
            : anchor.attributes['title'],
      );
    }

    // X-X-X exposes its creator as VideoObject.author in JSON-LD.
    void visit(Object? node) {
      if (node is List) {
        for (final child in node) {
          visit(child);
        }
      } else if (node is Map) {
        final type = node['@type'];
        final isPerson = type == 'Person' ||
            (type is List && type.contains('Person'));
        if (isPerson) {
          addModel(
            node['url']?.toString(),
            node['name']?.toString(),
            fromStructuredData: true,
          );
        }
        for (final value in node.values) {
          visit(value);
        }
      }
    }

    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        visit(jsonDecode(script.text));
      } catch (_) {
        // Ignore malformed JSON-LD and keep models found from page anchors.
      }
    }

    return models;
  }

  Future<ModelPageResult> modelPage(ModelRef model, {int page = 1}) async {
    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
    final uri = config.modelVideosUri(base, page);

    final String body;
    try {
      body = await _get(uri);
    } on ScraperException catch (error) {
      if (page > 1 &&
          (error.statusCode == 404 || error.statusCode == 410)) {
        return const ModelPageResult(
          videos: <Video>[],
          hasMore: false,
        );
      }
      rethrow;
    }

    final document = html.parse(body);
    final videos = _videosFrom(document, uri, config.cardSelector);
    final pagination = _modelPagination(
      document,
      base,
      pageUri: uri,
      section: 'videos',
      currentPage: page,
    );
    final hasMore = pagination.hasMore ??
        (config.searchSpacesAsUnderscores && videos.length < 40
            ? false
            : null);
    return ModelPageResult(
      videos: videos,
      profile: page <= 1 ? _modelProfile(document, uri, model) : null,
      nextPage: pagination.nextPage,
      hasMore: hasMore,
    );
  }

  _ModelPagination _modelPagination(
    dom.Document document,
    Uri modelBase, {
    required Uri pageUri,
    required String section,
    required int currentPage,
  }) {
    final baseSegments = modelBase.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (baseSegments.length < 2 || baseSegments.first != 'models') {
      return const _ModelPagination.unavailable();
    }

    final pages = <int>{};
    for (final anchor in document.querySelectorAll('a[href]')) {
      final target = _resolveHttp(anchor.attributes['href'], pageUri);
      if (target == null || target.host != modelBase.host) continue;
      final segments = target.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (segments.length < 3 ||
          segments[0] != baseSegments[0] ||
          segments[1] != baseSegments[1] ||
          segments[2] != section ||
          segments.length > 4) {
        continue;
      }
      final rawPage = segments.length == 3
          ? 1
          : (int.tryParse(segments[3]) ?? -1);
      final page = rawPage == 0 ? 1 : rawPage;
      if (page >= 1) pages.add(page);
    }

    final hasPaginationMarkup = document.querySelector(
          '.pagination, .pagination-holder, .pagination__wrap, '
          '.pagination-container, [class*=pagination], '
          'nav[aria-label*=pagination], #list_videos_videos_list_pagination',
        ) !=
        null;
    final hasPagination = hasPaginationMarkup || pages.isNotEmpty;
    if (!hasPagination) return const _ModelPagination.unavailable();

    final next = pages.where((value) => value > currentPage).toList()..sort();
    return _ModelPagination(
      nextPage: next.isEmpty ? null : next.first,
      hasMore: next.isNotEmpty,
    );
  }

  Future<ModelCatalogSummary> modelCatalogSummary(
    ModelRef model, {
    required ModelPageResult firstVideoPage,
    required List<AlbumRef> firstAlbumPage,
  }) {
    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
    final key = '${base.host}${base.path}';
    return _modelSummaryCache.fetch(
      key,
      () => _loadModelCatalogSummary(
        model,
        firstVideoPage: firstVideoPage,
        firstAlbumPage: firstAlbumPage,
      ),
    );
  }

  Future<ModelCatalogSummary> _loadModelCatalogSummary(
    ModelRef model, {
    required ModelPageResult firstVideoPage,
    required List<AlbumRef> firstAlbumPage,
  }) async {
    // Count the independent catalog sections concurrently. Each request parses
    // one listing page and discards its DOM/video cards before fetching the next
    // page; only integer totals and album IDs survive this pass.
    final videoCountFuture = _countModelVideos(model, firstVideoPage);
    final albumCountsFuture = _countModelAlbumsAndPhotos(
      model,
      firstAlbumPage,
    );
    final videoCount = await videoCountFuture;
    final albumCounts = await albumCountsFuture;
    return ModelCatalogSummary(
      videoCount: videoCount,
      albumCount: albumCounts.albumCount,
      photoCount: albumCounts.photoCount,
    );
  }

  Future<int> _countModelVideos(
    ModelRef model,
    ModelPageResult firstVideoPage,
  ) async {
    const maxSummaryPages = 300;
    const expectedPageSize = 40;
    var videoCount = firstVideoPage.videos.length;
    var nextVideoPage = firstVideoPage.nextPage;
    if (firstVideoPage.hasMore == null &&
        firstVideoPage.videos.length >= expectedPageSize) {
      nextVideoPage = 2;
    }
    final visitedVideoPages = <int>{1};
    for (var guard = 0;
        nextVideoPage != null && guard < maxSummaryPages;
        guard++) {
      final page = nextVideoPage;
      if (!visitedVideoPages.add(page)) break;
      final result = await modelPage(model, page: page);
      if (result.videos.isEmpty) break;
      videoCount += result.videos.length;
      if (result.hasMore == false) break;
      nextVideoPage = result.nextPage;
      if (nextVideoPage == null &&
          result.hasMore == null &&
          result.videos.length >= expectedPageSize) {
        nextVideoPage = page + 1;
      }
    }
    return videoCount;
  }

  Future<_AlbumCatalogCounts> _countModelAlbumsAndPhotos(
    ModelRef model,
    List<AlbumRef> firstAlbumPage,
  ) async {
    const maxSummaryPages = 300;
    const albumMetadataConcurrency = 4;
    final seenAlbums = <String>{};
    var albumCount = 0;
    var photoCount = 0;
    var allPhotoCountsKnown = true;

    Future<void> addAlbumMetadata(Iterable<AlbumRef> albums) async {
      final freshAlbums = <AlbumRef>[];
      for (final album in albums) {
        if (seenAlbums.add(album.id)) freshAlbums.add(album);
      }
      albumCount += freshAlbums.length;

      // Fetch album count headers in small batches only when the listing card
      // does not expose a count. No photo objects or thumbnails are retained.
      for (var offset = 0;
          offset < freshAlbums.length;
          offset += albumMetadataConcurrency) {
        final batch = freshAlbums.skip(offset).take(albumMetadataConcurrency);
        final counts = await Future.wait<int?>(batch.map((album) async {
          if (album.totalCount != null) return album.totalCount;
          try {
            return await albumPhotoCount(album);
          } catch (_) {
            return null;
          }
        }));
        for (final count in counts) {
          if (count == null) {
            allPhotoCountsKnown = false;
          } else {
            photoCount += count;
          }
        }
      }
    }

    await addAlbumMetadata(firstAlbumPage);
    if (firstAlbumPage.isNotEmpty) {
      for (var page = 2; page <= maxSummaryPages + 1; page++) {
        final albums = await modelAlbums(model, page: page);
        if (albums.isEmpty) break;
        final before = seenAlbums.length;
        await addAlbumMetadata(albums);
        if (seenAlbums.length == before) break;
      }
    }

    return _AlbumCatalogCounts(
      albumCount: albumCount,
      photoCount: allPhotoCountsKnown ? photoCount : null,
    );
  }

  String? _imageSource(dom.Element? image) {
    if (image == null) return null;
    const names = <String>[
      'data-src',
      'data-lazy-src',
      'data-original-src',
      'data-original',
      'data-webp',
      'data-srcset',
      'srcset',
      'src',
    ];
    for (final name in names) {
      final value = image.attributes[name]?.trim();
      if (value == null || value.isEmpty || value.startsWith('data:')) continue;
      if (name.endsWith('srcset')) return _bestSrcsetUrl(value);
      return value;
    }
    return null;
  }

  String? _bestSrcsetUrl(String srcset) {
    String? best;
    var bestWidth = -1;
    for (final candidate in srcset.split(',')) {
      final parts = candidate.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty || parts.first.startsWith('data:')) {
        continue;
      }
      final descriptor = parts.length > 1 ? parts.last : '';
      final width = int.tryParse(descriptor.replaceFirst(RegExp(r'w$'), ''));
      final score = width ?? (descriptor.endsWith('x')
          ? ((double.tryParse(descriptor.substring(0, descriptor.length - 1)) ?? 0) * 1000).round()
          : 0);
      if (best == null || score > bestWidth) {
        best = parts.first;
        bestWidth = score;
      }
    }
    return best;
  }

  String? _albumImageSource(dom.Element card) {
    final image = _imageSource(card.querySelector('img'));
    if (image != null) return image;
    final source = card.querySelector('picture source[srcset]');
    final srcset = source?.attributes['data-srcset'] ??
        source?.attributes['srcset'];
    if (srcset != null) {
      final candidate = _bestSrcsetUrl(srcset);
      if (candidate != null) return candidate;
    }
    for (final element in <dom.Element?>[
      card,
      card.querySelector('.img-holder'),
      card.querySelector('[style*="background"]'),
    ]) {
      final style = element?.attributes['style'];
      if (style == null) continue;
      final match = RegExp(
        r'''background(?:-image)?\s*:[^;]*?url\((?:["']?)(.*?)(?:["']?)\)''',
        caseSensitive: false,
      ).firstMatch(style);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Reads only the album page's count metadata. It does not parse or keep
  /// the photo grid, so model summary counts do not populate photo memory.
  Future<int?> albumPhotoCount(AlbumRef album) async {
    final uri = Uri.parse(album.url);
    final body = await _get(uri);
    return _albumTotalCount(html.parse(body));
  }

  Future<List<AlbumRef>> modelAlbums(ModelRef model, {int page = 1}) async {
    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
    final uri = page <= 1
        ? base.resolve('albums/')
        : base.resolve('albums/$page/');

    Future<List<AlbumRef>> fromSearch() async {
      final searchPage = config.searchUri(model.name, page);
      final searchBody = await _get(searchPage);
      return _albumsFrom(
        html.parse(searchBody),
        searchPage,
        modelName: model.name,
      );
    }

    try {
      final body = await _get(uri);
      final albums = _albumsFrom(html.parse(body), uri, modelName: model.name);
      if (albums.isNotEmpty || !config.searchSpacesAsUnderscores) {
        return albums;
      }
      // X-X-X does not consistently expose a dedicated model-albums route;
      // its search page can also contain matching album cards.
      return await fromSearch();
    } on ScraperException catch (error) {
      if (!config.searchSpacesAsUnderscores) {
        if (page > 1 &&
          (error.statusCode == 404 || error.statusCode == 410)) {
          return const <AlbumRef>[];
        }
        rethrow;
      }
      // X-X-X model album pages can be absent (404) while paginated search
      // results still expose the model's albums. Always try that fallback.
      try {
        return await fromSearch();
      } on ScraperException catch (fallbackError) {
        if (page > 1 && fallbackError.statusCode == 404) {
          return const <AlbumRef>[];
        }
        rethrow;
      }
    }
  }

  Future<List<AlbumRef>> allAlbums({int page = 1}) async {
    final uri = page <= 1
        ? config.baseUri.resolve('albums/')
        : config.baseUri.resolve('albums/$page/');
    final String body;
    try {
      body = await _get(uri);
    } on ScraperException catch (error) {
      if (page > 1 && error.statusCode == 404) return const <AlbumRef>[];
      rethrow;
    }
    return _albumsFrom(html.parse(body), uri);
  }

  List<AlbumRef> _albumsFrom(
    dom.Document document,
    Uri uri, {
    String? modelName,
  }) {
    var cards = document.querySelectorAll('.thumb--albums');
    if (cards.isEmpty) {
      cards = document
          .querySelectorAll(config.cardSelector)
          .where((c) => c.querySelector('a[href*="/albums/"]') != null)
          .toList();
    }

    final albums = <AlbumRef>[];
    final seen = <String>{};
    for (final card in cards) {
      final anchor = card.localName == 'a'
          ? card
          : card.querySelector('a[href]');
      final target = _resolveHttp(anchor?.attributes['href'], uri);
      if (anchor == null || target == null) continue;
      final segments = target.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2 || segments.first.toLowerCase() != 'albums') {
        continue;
      }
      final id = '${target.host}${target.path}';
      if (!seen.add(id)) continue;

      final image = card.querySelector('img');
      var title = _collapse(anchor.attributes['title'] ?? '');
      if (title.isEmpty) {
        title = _collapse(
          card.querySelector('.thumb__title, .title')?.text ?? '',
        );
      }
      if (title.isEmpty) title = _collapse(image?.attributes['alt'] ?? '');
      if (title.isEmpty) {
        title = segments.last.replaceAll(RegExp(r'[-_]+'), ' ').trim();
      }
      albums.add(
        AlbumRef(
          id: id,
          title: title,
          url: target.toString(),
          thumbnailUrl: _absoluteUrl(_albumImageSource(card), uri),
          modelName: modelName,
          totalCount: _albumTotalFromCard(card),
        ),
      );
    }
    return albums;
  }

  Future<List<AlbumPhoto>> albumPhotos(AlbumRef album, {int chunk = 0}) async =>
      (await albumPhotosPage(album, chunk: chunk)).photos;

  Future<AlbumPhotosPage> albumPhotosPage(
    AlbumRef album, {
    int chunk = 0,
  }) async {
    final base = Uri.parse(album.url);
    final Uri uri;
    Map<String, String>? extra;
    if (chunk <= 0) {
      uri = base;
    } else {
      uri = base.replace(
        queryParameters: <String, String>{
          ...base.queryParameters,
          'mode': 'async',
          'function': 'get_block',
          'block_id': 'album_view_album_view',
          'load': 'more',
          'from': '$chunk',
        },
      );
      extra = <String, String>{
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': album.url,
        'Accept': '*/*',
      };
    }

    final String body;
    try {
      body = await _get(uri, extraHeaders: extra);
    } on ScraperException catch (error) {
      final status = error.statusCode;
      if (chunk > 0 && status != null && status >= 400 && status < 500) {
        return const AlbumPhotosPage(photos: <AlbumPhoto>[]);
      }
      rethrow;
    }
    final document = html.parse(body);

    var anchors = document.querySelectorAll('a.grid-item[href]');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll(
        '#albumGallery .item a[href], .album-view .item a[href], .photo-holder .item a[href]',
      );
    }

    final photos = <AlbumPhoto>[];
    final seen = <String>{};
    for (final anchor in anchors) {
      final image = anchor.querySelector('img');
      if (image == null) continue;
      final full = _absoluteUrl(anchor.attributes['href'], uri);
      if (full == null) continue;
      final thumb = _absoluteUrl(_imageSource(image), uri) ?? full;
      final id = _photoId(full);
      if (!seen.add(id)) continue;
      photos.add(AlbumPhoto(id: id, thumbUrl: thumb, fullUrl: full));
    }
    return AlbumPhotosPage(
      photos: photos,
      totalCount: chunk == 0 ? _albumTotalCount(document) : null,
    );
  }

  int? _albumTotalCount(dom.Document document) {
    for (final label in document.querySelectorAll('.media-data__list-title')) {
      final normalized = _collapse(label.text).toLowerCase();
      if (normalized != 'images:' && normalized != 'photos:') continue;
      final value = label.parent?.querySelector('.media-data__list-value')?.text;
      final count = _parseImageCount(value);
      if (count != null) return count;
    }

    // This catalogue exposes an exact image count in the load-more label.
    // data-total on that button is the number of async batches, not images.
    final loadMoreLabel = document
        .querySelector('.js-ajax-images2')
        ?.text;
    final match = loadMoreLabel == null
        ? null
        : RegExp(
            r'([\d\s.,\u00a0]+)\s+(?:images|photos|pictures)\b',
            caseSensitive: false,
          ).firstMatch(loadMoreLabel);
    return _parseImageCount(match?.group(1));
  }

  int? _albumTotalFromCard(dom.Element card) {
    final candidates = <String?>[
      card.querySelector('i[class*="photo-shape"]')?.parent?.text,
      card.querySelector(
        '.photo-count, .photos-count, .album-photo-count, '
        '[data-photo-count], [class*=photo-count]',
      )?.text,
      card.attributes['data-photo-count'],
    ];
    for (final candidate in candidates) {
      final count = _parseImageCount(candidate);
      if (count != null) return count;
    }
    return null;
  }

  int? _parseImageCount(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final normalized = _collapse(raw);
    final labeled = RegExp(
      r'([\d][\d\s,._]*)\s*(?:photos?|images?|pictures?)\b',
      caseSensitive: false,
    ).firstMatch(normalized);
    final numeric = labeled?.group(1) ??
        (RegExp(r'^[\d\s,._]+$').hasMatch(normalized) ? normalized : null);
    if (numeric == null) return null;
    final digits = numeric.replaceAll(RegExp(r'[^\d]'), '');
    final count = int.tryParse(digits);
    return count != null && count <= 10000000 ? count : null;
  }

  static String _photoId(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final match = RegExp(r'/sources/(.+?)/?$').firstMatch(path);
    return match?.group(1) ?? path;
  }

  ModelProfile _modelProfile(
    dom.Document document,
    Uri pageUri,
    ModelRef model,
  ) {
    String? name;
    String? image;

    void walk(Object? node) {
      if (node is List) {
        node.forEach(walk);
      } else if (node is Map) {
        final type = node['@type'];
        final isPerson =
            type == 'Person' || (type is List && type.contains('Person'));
        if (isPerson && name == null) {
          final rawName = node['name']?.toString().trim() ?? '';
          if (rawName.isNotEmpty) name = rawName;
          final raw = node['image'];
          String? candidate;
          if (raw is String) {
            candidate = raw;
          } else if (raw is List && raw.isNotEmpty) {
            final first = raw.first;
            candidate = first is Map
                ? first['url']?.toString()
                : first?.toString();
          } else if (raw is Map) {
            candidate = raw['url']?.toString();
          }
          image = _absoluteUrl(candidate, pageUri);
        }
        node.values.forEach(walk);
      }
    }

    final blocks = document.querySelectorAll(
      'script[type="application/ld+json"]',
    );
    for (final script in blocks) {
      try {
        walk(jsonDecode(script.text));
      } catch (_) {}
    }

    if (image == null) {
      for (final selector in const [
        'meta[property="og:image"]',
        'meta[name="twitter:image"]',
        'link[rel="image_src"]',
      ]) {
        final element = document.querySelector(selector);
        final value =
            element?.attributes['content'] ?? element?.attributes['href'];
        final url = _absoluteUrl(value, pageUri);
        if (url != null &&
            !RegExp(r'logo|/static/', caseSensitive: false).hasMatch(url)) {
          image = url;
          break;
        }
      }
    }
    if (image == null) {
      for (final script in blocks) {
        final match = RegExp(r'"image"\s*:\s*"([^"]+)"')
            .firstMatch(script.text);
        final url = _absoluteUrl(
          match?.group(1)?.replaceAll(r'\/', '/'),
          pageUri,
        );
        if (url != null) {
          image = url;
          break;
        }
      }
    }
    if (name == null) {
      final raw = RegExp(r'"name"\s*:\s*"([^"]+)"');
      for (final script in blocks) {
        final match = raw.firstMatch(script.text);
        if (match != null) {
          name = match.group(1)!.trim();
          break;
        }
      }
    }
    return ModelProfile(name: name ?? model.name, imageUrl: image);
  }

  Future<ModelProfile> modelProfile(ModelRef model) async {
    final result = await modelPage(model);
    final profile = result.profile ?? ModelProfile(name: model.name);
    if (profile.imageUrl != null) return profile;

    // Model video pages can omit portraits that are available as lazy-loaded
    // .thumb--models images in the directory. Cache one directory response
    // instead of issuing a separate request for every model row.
    try {
      final images = await _modelDirectoryImages.fetch(
        'models-directory',
        () async {
          final uri = config.baseUri.resolve('models/');
          final directory = html.parse(await _get(uri));
          final result = <String, String>{};
          var cards = directory.querySelectorAll('.thumb--models');
          if (cards.isEmpty) {
            cards = directory
                .querySelectorAll(config.cardSelector)
                .where((card) =>
                    card.querySelector('a[href*="/models/"]') != null)
                .toList();
          }
          for (final card in cards) {
            final anchor = card.querySelector('a[href*="/models/"]') ??
                card.querySelector('a[href]');
            final target = _resolveHttp(anchor?.attributes['href'], uri);
            final modelUrl = target == null ? null : _modelBase(target);
            if (target == null || modelUrl == null) continue;
            final image = _absoluteUrl(_albumImageSource(card), target);
            if (image != null) result[modelUrl.toString()] = image;
          }
          return result;
        },
      );
      final wanted = _modelBase(Uri.parse(model.url));
      if (wanted == null) return profile;
      final image = images[wanted.toString()];
      if (image != null) {
        return ModelProfile(name: profile.name, imageUrl: image);
      }
    } on ScraperException {
      // Keep profile loading usable when the optional directory lookup fails.
    }
    return profile;
  }

  Future<PeopleSearchResult> searchPeople(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const PeopleSearchResult(models: [], albums: []);

    final models = <String, ModelRef>{};
    final albums = <String, AlbumRef>{};
    final slugs = <String>{
      ScraperConfig._slugify(q),
      q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''),
      if (config.searchSpacesAsUnderscores)
        q.toLowerCase().replaceAll(RegExp(r'\s+'), '_'),
    }..removeWhere((s) => s.isEmpty);

    // Resolve direct model pages first. This gives exact profile metadata and
    // lets us fetch the matching model's album listing separately.
    await Future.wait<void>([
      for (final slug in slugs)
        () async {
          final ref = ModelRef(
            name: q,
            url: config.baseUri.resolve('models/$slug/').toString(),
          );
          try {
            final page = await modelPage(ref);
            final profile = page.profile;
            final base = _modelBase(Uri.parse(ref.url)) ?? Uri.parse(ref.url);
            models.putIfAbsent(
              base.toString(),
              () => ModelRef(
                name: profile?.name ?? q,
                url: base.toString(),
                imageUrl: profile?.imageUrl,
              ),
            );
          } on ScraperException {
            // Search-page discovery below can still find the model.
          }
        }(),
    ]);

    try {
      final uri = config.searchUri(q, 1);
      final document = html.parse(await _get(uri));

      for (final anchor in document.querySelectorAll('a[href*="/models/"]')) {
        final target = _resolveHttp(anchor.attributes['href'], uri);
        final base = target == null ? null : _modelBase(target);
        if (base == null || models.containsKey(base.toString())) continue;
        var name = _collapse(anchor.text);
        if (name.isEmpty) name = _collapse(anchor.attributes['title'] ?? '');
        if (name.isEmpty) {
          name = _collapse(
            anchor.querySelector('img')?.attributes['alt'] ?? '',
          );
        }
        if (name.isEmpty) {
          name = base.pathSegments[1].replaceAll(RegExp(r'[-_]+'), ' ');
        }
        models[base.toString()] = ModelRef(
          name: name,
          url: base.toString(),
          imageUrl: _absoluteUrl(
            _imageSource(anchor.querySelector('img')),
            uri,
          ),
        );
      }

      // Some source search pages mix model results and album cards. Keep both.
      for (final album in _albumsFrom(document, uri)) {
        albums.putIfAbsent(album.id, () => album);
      }
    } on ScraperException catch (error) {
      debugPrint('[SCRAPER] People search page failed: ${error.message}');
    }

    final lower = q.toLowerCase();
    int rank(ModelRef m) {
      final n = m.name.toLowerCase();
      if (n == lower) return 0;
      if (n.startsWith(lower)) return 1;
      if (n.contains(lower)) return 2;
      return 3;
    }

    final sorted = models.values.toList()
      ..sort((a, b) => rank(a).compareTo(rank(b)));

    // Only request album pages for exact slug matches, not every model returned
    // by a broad search. This avoids unnecessary traffic on slow connections.
    final matchingModels = sorted
        .where((model) {
          final uri = Uri.tryParse(model.url);
          final base = uri == null ? null : _modelBase(uri);
          if (base == null || base.pathSegments.length < 2) return false;
          return slugs.contains(base.pathSegments[1].toLowerCase());
        })
        .take(2)
        .toList();

    await Future.wait<void>([
      for (final model in matchingModels)
        () async {
          try {
            final found = await modelAlbums(model);
            for (final album in found) {
              albums[album.id] = album;
            }
          } on ScraperException catch (error) {
            debugPrint('[SCRAPER] Model albums unavailable: ${error.message}');
          }
        }(),
    ]);

    final orderedAlbums = albums.values.toList()
      ..sort((a, b) {
        final aModel = a.modelName == null ? 1 : 0;
        final bModel = b.modelName == null ? 1 : 0;
        return aModel.compareTo(bModel);
      });

    return PeopleSearchResult(
      models: sorted.take(20).toList(),
      albums: orderedAlbums.take(40).toList(),
    );
  }

  late final RegExp? _videoPathRe = _safeRegExp(config.videoPathPattern);
  late final RegExp? _excludePathRe = _safeRegExp(config.excludePathPattern);

  static RegExp? _safeRegExp(String pattern) {
    if (pattern.trim().isEmpty) return null;
    try {
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  static final RegExp _leadingLikeRe = RegExp(r'^\s*(\d{1,3})\s*%');
  static final RegExp _percentRe = RegExp(r'(\d{1,3})\s*%');
  static final RegExp _durationRe = RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b');
  static final RegExp _viewsRe = RegExp(
    r'(\d[\d,.]*\s*[KkMm]?)\s*views?\b',
    caseSensitive: false,
  );
  static final RegExp _ageRe = RegExp(
    r'\b\d+\s+(?:second|minute|hour|day|week|month|year)s?(?:\s+ago)?\b',
    caseSensitive: false,
  );
  static final RegExp _photosRe = RegExp(
    r'\b\d+\s+(?:photos?|pics?|pictures?|images?)\b',
    caseSensitive: false,
  );

  static String _collapse(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  Uri? _resolveHttp(String? href, Uri base) {
    final cleaned = href?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    try {
      final uri = base.resolve(cleaned);
      return (uri.scheme == 'http' || uri.scheme == 'https') &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty
          ? uri
          : null;
    } catch (_) {
      return null;
    }
  }

  bool _isVideoUri(Uri uri) {
    final path = uri.path;
    final video = _videoPathRe;
    if (video != null && !video.hasMatch(path)) return false;
    final excluded = _excludePathRe;
    if (excluded != null && excluded.hasMatch(path)) return false;
    return true;
  }

  static bool _isPolluted(String text) =>
      _leadingLikeRe.hasMatch(text) || _viewsRe.hasMatch(text);

  static String _cleanTitle(String text) {
    var title = text.replaceFirst(RegExp(r'^\s*\d{1,3}\s*%\s*'), '');
    final duration = _durationRe.firstMatch(title)?.group(0);
    if (duration != null) title = title.replaceFirst(duration, '');
    title = title.replaceAll(_viewsRe, '').replaceAll(_ageRe, '');
    return _collapse(title);
  }

  String? _iconText(dom.Element element, String selector) {
    if (selector.trim().isEmpty) return null;
    final icon = element.querySelector(selector);
    if (icon == null) return null;
    final dom.Node node = icon.parent ?? icon;
    final text = _collapse(node.text ?? '');
    return text.isEmpty ? null : text;
  }

  static String _compactNumber(double v) => v >= 100
      ? v.round().toString()
      : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');

  static String _normalizeViews(String raw) {
    final text = _collapse(
      raw.replaceAll(RegExp(r'views?', caseSensitive: false), ''),
    );
    if (text.isEmpty) return '';

    final match = RegExp(r'^(\d[\d.,\s\u00a0]*?)\s*([KkMmBb])?$')
        .firstMatch(text);
    if (match == null) return '';

    final number = match.group(1)!.replaceAll(RegExp(r'[\s\u00a0]'), '');
    final suffix = match.group(2)?.toUpperCase();

    if (suffix != null) {
      final value = double.tryParse(number.replaceAll(',', '.'));
      return value == null ? '' : '${_compactNumber(value)}$suffix views';
    }

    final count = int.tryParse(number.replaceAll(RegExp(r'[^\d]'), ''));
    if (count == null) return '';
    if (count >= 1000000000) return '${_compactNumber(count / 1e9)}B views';
    if (count >= 1000000) return '${_compactNumber(count / 1e6)}M views';
    if (count >= 1000) return '${_compactNumber(count / 1e3)}K views';
    return count == 1 ? '1 view' : '$count views';
  }

  String _normalCardTitle({
    required dom.Element? anchor,
    required dom.Element card,
    required dom.Element? titleElement,
    required dom.Element? image,
    required String anchorText,
    required String cardText,
  }) {
    var title = (anchor?.attributes['title'] ??
            card.attributes['data-title'] ??
            titleElement?.text ??
            image?.attributes['alt'] ??
            anchorText)
        .trim();
    title = _isPolluted(title) ? _cleanTitle(title) : _collapse(title);
    if (title.isEmpty) title = _cleanTitle(anchorText);
    if (title.isEmpty) title = _cleanTitle(cardText);
    return title;
  }

  /// X-X-X truncates visible `.title` text on some search cards while keeping
  /// the complete value in a title/data-title attribute. Compare dedicated
  /// title fields and keep the most complete non-empty candidate.
  String _xXxCardTitle({
    required dom.Element? anchor,
    required dom.Element card,
    required dom.Element? titleElement,
    required dom.Element? image,
    required String anchorText,
    required String cardText,
  }) {
    final dedicatedCandidates = <String?>[
      anchor?.attributes['title'],
      anchor?.attributes['data-title'],
      card.attributes['data-title'],
      card.attributes['title'],
      titleElement?.attributes['title'],
      titleElement?.attributes['data-title'],
      titleElement?.text,
    ];

    final candidates = <String>[];
    for (final raw in dedicatedCandidates) {
      if (raw == null || raw.trim().isEmpty) continue;
      final value = _isPolluted(raw) ? _cleanTitle(raw) : _collapse(raw);
      if (value.isEmpty || _isGenericCardTitle(value)) continue;
      if (!candidates.contains(value)) candidates.add(value);
    }

    if (candidates.isNotEmpty) {
      // Longer values generally come from the full tooltip attribute, while
      // visible search-card text may be shortened with an ellipsis. Keep the
      // first candidate when lengths tie (anchor[title] is first).
      var best = candidates.first;
      for (final candidate in candidates.skip(1)) {
        if (candidate.length > best.length) best = candidate;
      }
      return best;
    }

    for (final raw in <String?>[
      image?.attributes['alt'],
      anchorText,
      cardText,
    ]) {
      if (raw == null || raw.trim().isEmpty) continue;
      final value = _isPolluted(raw) ? _cleanTitle(raw) : _collapse(raw);
      if (value.isNotEmpty && !_isGenericCardTitle(value)) return value;
    }
    return '';
  }

  bool _isGenericCardTitle(String value) {
    final normalized = value.toLowerCase().trim();
    return normalized == 'play' ||
        normalized == 'watch' ||
        normalized == 'watch video' ||
        normalized == 'play video' ||
        normalized == 'video';
  }

  Video? _parseCard(dom.Element element, Uri pageUri) {
    final anchors = <dom.Element>[
      if (element.localName == 'a') element,
      ...element.querySelectorAll(config.anchorSelector),
    ];
    dom.Element? anchor;
    Uri? videoPage;
    for (final candidate in anchors) {
      final uri = _resolveHttp(candidate.attributes['href'], pageUri);
      if (uri != null && _isVideoUri(uri)) {
        anchor = candidate;
        videoPage = uri;
        break;
      }
    }
    if (videoPage == null) {
      final uri = _resolveHttp(
        element.attributes['data-href'] ?? element.attributes['data-url'],
        pageUri,
      );
      if (uri != null && _isVideoUri(uri)) videoPage = uri;
    }
    if (videoPage == null) return null;

    final classes = element.className.toLowerCase();
    if (classes.contains('album') || classes.contains('gallery')) return null;

    final anchorText = _collapse(anchor?.text ?? '');
    final cardText = _collapse(element.text);
    final texts = <String>[anchorText, cardText];

    var likes = '';
    for (final text in texts) {
      final match = _leadingLikeRe.firstMatch(text);
      if (match != null) {
        likes = '${match.group(1)}%';
        break;
      }
    }
    if (likes.isEmpty) {
      final raw =
          _text(element, config.likesSelector) ??
          element.attributes['data-rating'] ??
          element.attributes['data-likes'];
      final match = raw == null ? null : _percentRe.firstMatch(raw);
      if (match != null) likes = '${match.group(1)}%';
    }

    var duration =
        _durationRe
            .firstMatch(_iconText(element, config.durationIconSelector) ?? '')
            ?.group(1) ??
        '';
    if (duration.isEmpty) {
      duration =
          _durationRe
              .firstMatch(_text(element, config.durationSelector) ?? '')
              ?.group(1) ??
          '';
    }
    if (duration.isEmpty) {
      for (final node in element.querySelectorAll(
        'li, [class*="duration"], [data-duration]',
      )) {
        final value = _collapse(node.text);
        final match = _durationRe.firstMatch(value);
        if (match != null) {
          duration = match.group(1)!;
          break;
        }
      }
    }
    if (duration.isEmpty) {
      for (final text in texts) {
        final match = _durationRe.firstMatch(text);
        if (match != null) {
          duration = match.group(1)!;
          break;
        }
      }
    }
    // Fall back to the markup itself for sites whose duration is inside an
    // inline template or lazy-rendered data node with no text node yet.
    if (duration.isEmpty) {
      final markupDuration = RegExp(r'\d{1,2}:\d{2}(?::\d{2})?')
          .firstMatch(element.innerHtml);
      duration = markupDuration?.group(0) ?? '';
    }
    if (duration.isEmpty) duration = element.attributes['data-duration'] ?? '';

    if (duration.isEmpty && _photosRe.hasMatch(cardText)) return null;

    var views = _normalizeViews(
      _iconText(element, config.viewsIconSelector) ?? '',
    );
    if (views.isEmpty) {
      for (final text in texts) {
        final match = _viewsRe.firstMatch(text);
        if (match != null) {
          views = _normalizeViews(match.group(1)!);
          if (views.isNotEmpty) break;
        }
      }
    }
    if (views.isEmpty) {
      views = _normalizeViews(
        _text(element, config.viewsSelector) ??
            element.attributes['data-views'] ??
            '',
      );
    }

    final date = _collapse(_iconText(element, config.dateIconSelector) ?? '');

    final image = element.querySelector(config.imageSelector);
    final thumbnailRaw =
        image?.attributes['data-src'] ??
        image?.attributes['data-original'] ??
        image?.attributes['data-lazy-src'] ??
        image?.attributes['src'] ??
        element.querySelector('video[poster]')?.attributes['poster'];
    final thumbnail = _absoluteUrl(thumbnailRaw, pageUri);

    final titleElement = element.querySelector(config.titleSelector);
    final title = config.baseUri.host.toLowerCase() == 'x-x-x.tube'
        ? _xXxCardTitle(
            anchor: anchor,
            card: element,
            titleElement: titleElement,
            image: image,
            anchorText: anchorText,
            cardText: cardText,
          )
        : _normalCardTitle(
            anchor: anchor,
            card: element,
            titleElement: titleElement,
            image: image,
            anchorText: anchorText,
            cardText: cardText,
          );
    if (title.isEmpty) return null;

    final rawId =
        element.attributes['data-id'] ?? '${videoPage.host}${videoPage.path}';
    final id = rawId.length <= 512 ? rawId : rawId.substring(0, 512);
    final directStream = _directStreamFromCard(element, pageUri);
    final previewUrl =
        _absoluteUrl(
          image?.attributes['data-preview'] ??
              element
                  .querySelector('[data-preview]')
                  ?.attributes['data-preview'],
          pageUri,
        ) ??
        '';

    return Video(
      id: id,
      title: title.length <= 300 ? title : title.substring(0, 300),
      streamUrl: directStream ?? '',
      pageUrl: videoPage.toString(),
      previewUrl: previewUrl,
      thumbnailUrl: thumbnail,
      duration: duration.length <= 64 ? duration : duration.substring(0, 64),
      views: views.length <= 64 ? views : views.substring(0, 64),
      likes: likes.length <= 64 ? likes : likes.substring(0, 64),
      date: date.length <= 64 ? date : date.substring(0, 64),
      category: _collapse(element.attributes['data-category'] ?? 'Video')
          .substring(
            0,
            _collapse(element.attributes['data-category'] ?? 'Video').length
                .clamp(0, 100)
                .toInt(),
          ),
    );
  }

  String? _text(dom.Element element, String selector) {
    if (selector.trim().isEmpty) return null;
    return element.querySelector(selector)?.text.trim();
  }

  String? _directStreamFromCard(dom.Element element, Uri pageUri) {
    final raw =
        element.attributes['data-video-url'] ??
        element.attributes['data-stream'] ??
        element.querySelector('video source[src]')?.attributes['src'] ??
        element.querySelector('video[src]')?.attributes['src'];
    return _absoluteUrl(raw, pageUri);
  }

  String? _absoluteUrl(String? value, Uri contextUri) {
    final cleaned = value?.trim();
    if (cleaned == null ||
        cleaned.isEmpty ||
        cleaned.startsWith('data:') ||
        cleaned.startsWith('javascript:')) {
      return null;
    }
    try {
      final uri = contextUri.resolve(cleaned);
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.toString().length > 8192) {
        return null;
      }
      return uri.toString();
    } catch (_) {
      return null;
    }
  }

  String? _capture(String text, String pattern) {
    try {
      return RegExp(
        pattern,
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(text)?.group(1);
    } catch (_) {
      return null;
    }
  }

  static final RegExp _mediaExtRe = RegExp(
    r'\.(?:mp4|m3u8|webm|mkv|mov|m4v|mpd)(?:$|[/?#&])',
    caseSensitive: false,
  );
  static final RegExp _notMediaExtRe = RegExp(
    r'\.(?:jpe?g|png|gif|webp|svg|ico|css|js|json|vtt|srt|woff2?|ttf|html?)(?:$|[?#])',
    caseSensitive: false,
  );
  static final RegExp _previewRe = RegExp(
    r'preview|trailer|teaser|sprite|screenshot|thumb',
    caseSensitive: false,
  );

  static String _unescape(String value) => value
      .trim()
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\u003d', '=')
      .replaceAll('&amp;', '&');

  static bool _looksPlayable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    final path = uri.path.toLowerCase();
    if (_notMediaExtRe.hasMatch(path)) return false;
    final withQuery = uri.hasQuery ? '$path?${uri.query.toLowerCase()}' : path;
    return _mediaExtRe.hasMatch(withQuery) || path.contains('/get_file/');
  }

  static int _qualityOf(String text) {
    final lower = text.toLowerCase();
    final p = RegExp(r'(\d{3,4})\s*p').firstMatch(lower);
    if (p != null) return int.parse(p.group(1)!);
    if (lower.contains('4k') || lower.contains('2160')) return 2160;
    if (lower.contains('fhd') || lower.contains('1080')) return 1080;
    if (lower.contains('hd')) return 720;
    if (lower.contains('sd')) return 360;
    return 0;
  }

  Iterable<String> _captureAll(String text, String pattern, {int limit = 20}) {
    try {
      return RegExp(pattern, caseSensitive: false, dotAll: true)
          .allMatches(text)
          .map((match) => match.group(1))
          .whereType<String>()
          .take(limit)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  ({String? best, List<StreamQuality> options, bool needsDecoding})
  _extractStreams(String body, dom.Document document, Uri base) {
    final candidates = <_StreamCandidate>[];
    var needsDecoding = false;

    void add(String? raw, int rank, {String label = ''}) {
      if (raw == null) return;
      final value = _unescape(raw);
      if (value.isEmpty) return;
      if (value.startsWith('function/')) {
        needsDecoding = true;
        return;
      }
      final url = _absoluteUrl(value, base);
      if (url == null || !_looksPlayable(url)) return;
      final path = Uri.tryParse(url)?.path ?? url;
      candidates.add(
        _StreamCandidate(
          url,
          rank: rank,
          order: candidates.length,
          quality: _qualityOf(label.isNotEmpty ? label : path),
          preview: _previewRe.hasMatch(path),
        ),
      );
    }

    final urls = <String, String>{};
    final labels = <String, String>{};
    for (final m in RegExp(
      r"""(video_(?:alt_)?url\d*)\s*[:=]\s*["']([^"']+)["']""",
      caseSensitive: false,
    ).allMatches(body)) {
      urls.putIfAbsent(m.group(1)!.toLowerCase(), () => m.group(2)!);
    }
    for (final m in RegExp(
      r"""(video_(?:alt_)?url\d*)_text\s*[:=]\s*["']([^"']*)["']""",
      caseSensitive: false,
    ).allMatches(body)) {
      labels.putIfAbsent(m.group(1)!.toLowerCase(), () => m.group(2)!);
    }
    urls.forEach((key, value) => add(value, 0, label: labels[key] ?? ''));

    for (final node in document.querySelectorAll(
      'video source[src], video[src]',
    )) {
      final label =
          node.attributes['label'] ??
          node.attributes['title'] ??
          node.attributes['res'] ??
          node.attributes['size'] ??
          node.attributes['data-res'] ??
          '';
      add(node.attributes['src'], 1, label: label);
    }

    for (final selector in const [
      'meta[property="og:video"]',
      'meta[property="og:video:url"]',
      'meta[property="og:video:secure_url"]',
      'meta[name="twitter:player:stream"]',
    ]) {
      add(document.querySelector(selector)?.attributes['content'], 2);
    }

    for (final value in _captureAll(body, r'"contentUrl"\s*:\s*"([^"]+)"')) {
      add(value, 3);
    }

    for (final value in _captureAll(body, config.streamUrlPattern)) {
      add(value, 4);
    }

    final plain = body.replaceAll(r'\/', '/');
    for (final value in _captureAll(
      plain,
      r"""(https?://[^\s"'<>\\]+?\.(?:mp4|m3u8|webm)[^\s"'<>\\]*)""",
      limit: 30,
    )) {
      add(value, 5);
    }

    final seen = <String>{};
    final unique = candidates.where((c) => seen.add(c.url)).toList()
      ..sort((x, y) {
        if (x.preview != y.preview) return x.preview ? 1 : -1;
        final byScore = y.score.compareTo(x.score);
        if (byScore != 0) return byScore;
        final byRank = x.rank.compareTo(y.rank);
        return byRank != 0 ? byRank : x.order.compareTo(y.order);
      });

    final heights = <int>{};
    final options = <StreamQuality>[
      for (final c in unique)
        if (!c.preview && c.quality > 0 && heights.add(c.quality))
          StreamQuality(height: c.quality, url: c.url),
    ]..sort((x, y) => y.height.compareTo(x.height));

    return (
      best: unique.isEmpty ? null : unique.first.url,
      options: options.length < 2 ? const <StreamQuality>[] : options,
      needsDecoding: needsDecoding,
    );
  }

  Map<String, dynamic>? _videoObjectFromJsonLd(dom.Document document) {
    Map<String, dynamic>? found;

    void visit(Object? node) {
      if (found != null) return;
      if (node is List) {
        for (final child in node) {
          visit(child);
          if (found != null) return;
        }
      } else if (node is Map) {
        final type = node['@type'];
        final isVideo = type == 'VideoObject' ||
            (type is List && type.contains('VideoObject'));
        if (isVideo) {
          found = Map<String, dynamic>.from(node);
          return;
        }
        for (final value in node.values) {
          visit(value);
          if (found != null) return;
        }
      }
    }

    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        visit(jsonDecode(script.text));
      } catch (_) {
        // Ignore unrelated or malformed JSON-LD blocks.
      }
      if (found != null) break;
    }
    return found;
  }

  String? _jsonLdString(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is List && value.isNotEmpty) return _jsonLdString(value.first);
    if (value is Map) {
      return _jsonLdString(value['url'] ?? value['contentUrl']);
    }
    return null;
  }

  Future<Video> resolveForPlayback(Video video, {bool fresh = false}) async {
    if (video.streamUrl.trim().isNotEmpty) return video;
    final pageUrl = video.pageUrl;
    if (pageUrl == null || pageUrl.trim().isEmpty) {
      throw const ScraperException('This item has no detail-page URL.');
    }

    final uri = config.baseUri.resolve(pageUrl);
    final body = await _getDetailPage(uri, fresh: fresh);
    final job = (config: config, video: video, body: body, uri: uri);
    return _runInBackground(_resolveJob, job);
  }

  Video _videoFromPage(Video video, String body, Uri uri) {
    final document = html.parse(body);

    final videoObject = _videoObjectFromJsonLd(document);
    final picked = _extractStreams(body, document, uri);
    final streamUrl = picked.best;
    if (streamUrl == null) {
      throw ScraperException(
        picked.needsDecoding
            ? 'The source did not expose a direct video URL; this scraper supports direct media URLs only.'
            : 'No direct stream URL was found. Check the source selectors or use an authorized direct media URL.',
      );
    }

    final title =
        _capture(body, r"""video_title\s*[:=]\s*["']([^"']*)["']""") ??
        document.querySelector('h1')?.text.trim() ??
        document
            .querySelector('meta[property="og:title"]')
            ?.attributes['content']
            ?.trim() ??
        _jsonLdString(videoObject?['name']) ??
        _capture(body, config.detailTitlePattern) ??
        video.title;
    final descriptionNode = document.querySelector(config.descriptionSelector);
    final description =
        descriptionNode?.attributes['content']?.trim().isNotEmpty == true
        ? descriptionNode!.attributes['content']!.trim()
        : (descriptionNode?.text.trim().isNotEmpty == true
              ? descriptionNode!.text.trim()
              : _jsonLdString(videoObject?['description']) ?? video.description);
    final thumbnail =
        _absoluteUrl(
          _capture(body, r"""preview_url1?\s*[:=]\s*["']([^"']+)["']""") ??
              _capture(body, config.previewPattern) ??
              document.querySelector('video[poster]')?.attributes['poster'] ??
              _jsonLdString(videoObject?['thumbnailUrl']),
          uri,
        ) ??
        video.thumbnailUrl;

    return video.copyWith(
      title: title.trim().isEmpty
          ? video.title
          : (title.trim().length <= 300
                ? title.trim()
                : title.trim().substring(0, 300)),
      streamUrl: streamUrl.length <= 8192 ? streamUrl : '',
      description: description.length <= 1500
          ? description
          : description.substring(0, 1500),
      thumbnailUrl: thumbnail,
      pageUrl: uri.toString(),
      qualities: picked.options,
    );
  }

  Future<List<Video>> related(
    Video video, {
    int limit = 6,
    bool fresh = false,
  }) async {
    final pageUrl = video.pageUrl;
    if (pageUrl == null ||
        pageUrl.isEmpty ||
        config.relatedCardSelector.isEmpty) {
      return const <Video>[];
    }
    try {
      return (await list(
        config.baseUri.resolve(pageUrl),
        related: true,
        fresh: fresh,
      ))
          .where((item) => item.id != video.id)
          .take(limit < 0 ? 0 : limit)
          .toList();
    } catch (_) {
      if (fresh) rethrow;
      return const <Video>[];
    }
  }

  void close() => _client.close();
}

Future<R> _runInBackground<A, R>(R Function(A) job, A argument) async {
  try {
    return await Isolate.run<R>(() => job(argument));
  } on IsolateSpawnException {
    return job(argument);
  }
}

List<Video> _parseListJob(
  ({ScraperConfig config, String body, Uri uri, String selector}) job,
) {
  final scraper = Scraper(job.config);
  try {
    return scraper._videosFrom(html.parse(job.body), job.uri, job.selector);
  } finally {
    scraper.close();
  }
}

Video _resolveJob(
  ({ScraperConfig config, Video video, String body, Uri uri}) job,
) {
  final scraper = Scraper(job.config);
  try {
    return scraper._videoFromPage(job.video, job.body, job.uri);
  } finally {
    scraper.close();
  }
}

class _StreamCandidate {
  const _StreamCandidate(
    this.url, {
    required this.rank,
    required this.order,
    required this.quality,
    required this.preview,
  });

  final String url;

  final int rank;

  final int order;
  final int quality;
  final bool preview;

  int get score => quality <= 0 ? 1 : (quality > 1080 ? 1000 : quality);
}


class _AlbumCatalogCounts {
  const _AlbumCatalogCounts({
    required this.albumCount,
    required this.photoCount,
  });

  final int albumCount;
  final int? photoCount;
}

class _ModelPagination {
  const _ModelPagination({this.nextPage, required this.hasMore});
  const _ModelPagination.unavailable() : nextPage = null, hasMore = null;

  final int? nextPage;
  final bool? hasMore;
}

