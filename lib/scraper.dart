import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'request_cache.dart';

class ScraperConfig {
  const ScraperConfig({
    required this.baseUrl,
    this.homePath = '/',
    this.pagePathTemplate = '/video/{page}/',
    this.searchPathTemplate = '/search/{query}/{page}/',
    this.categoryPathTemplate = '/categories/{slug}/{page}/',
    this.cardSelector =
        '.thumbs__list .item.thumb, .thumb-spot, article[data-video], .video-card, .video-item',
    this.anchorSelector = 'a[href]',
    this.imageSelector = 'img',
    this.titleSelector =
        '[itemprop="name"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3',
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
    this.relatedCardSelector =
        '.related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item',
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
    this.timeout = const Duration(seconds: 20),
    this.categories = const <String>[],
  });

  final String baseUrl;
  final String homePath;
  final String pagePathTemplate;
  final String searchPathTemplate;
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
      pagePathTemplate.replaceAll('{page}', safePage.toString()),
    );
  }

  Uri searchUri(String query, int page) {
    final safePage = page < 1 ? 1 : page;
    var template = searchPathTemplate;
    if (safePage == 1 && template.contains('/{page}/')) {
      template = template.replaceFirst('/{page}/', '/');
    }
    return baseUri.resolve(
      template
          .replaceAll('{query}', Uri.encodeComponent(query.trim()))
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

  static String _slugify(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');
}

class ScraperException implements Exception {
  const ScraperException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

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

  Future<String> _getDetailPage(Uri uri, {bool fresh = false}) =>
      _detailPages.fetch(uri.toString(), () => _get(uri), force: fresh);

  Future<String> _get(Uri uri, {Map<String, String>? extraHeaders}) async {
    ScraperException? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _getOnce(uri, extraHeaders);
      } on ScraperException catch (error) {
        final status = error.statusCode;
        if (status != null && status < 500) {
          rethrow;
        }
        lastError = error;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw lastError ?? const ScraperException('The source could not be read.');
  }

  Future<String> _getOnce(Uri uri, Map<String, String>? extraHeaders) async {
    try {
      final response = await _client
          .get(uri, headers: <String, String>{..._headers, ...?extraHeaders})
          .timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ScraperException(
          'Source request failed with HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final declaresOther =
          contentType.contains('charset') && !contentType.contains('utf-8');
      final body = declaresOther
          ? response.body
          : utf8.decode(response.bodyBytes, allowMalformed: true);
      if (body.trim().isEmpty) {
        throw const ScraperException('The source returned an empty page.');
      }
      return body;
    } on ScraperException {
      rethrow;
    } on Exception catch (error) {
      debugPrint('[SCRAPER] Request failed for ${uri.origin} (${error.runtimeType}).');
      throw const ScraperException('Could not reach the video source.');
    }
  }

  Future<List<Video>> home({int page = 0}) {
    return list(page == 0 ? config.homeUri() : config.pageUri(page));
  }

  Future<List<Video>> search(String query, {int page = 1, String? sortBy}) {
    if (query.trim().isEmpty) return Future.value(const <Video>[]);
    var uri = config.searchUri(query, page);
    if (sortBy != null && sortBy.isNotEmpty) {
      uri = uri.replace(queryParameters: <String, String>{
        ...uri.queryParameters,
        'by': sortBy,
      });
    }
    return list(uri);
  }

  Future<List<Video>> category(String slug, {int page = 1}) {
    return list(config.categoryUri(slug, page));
  }

  Future<List<Video>> list(Uri uri, {bool related = false}) async {
    final body = related ? await _getDetailPage(uri) : await _get(uri);
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
        debugPrint('[SCRAPER] Skipped an invalid video card: $error');
      }
    }
    return videos;
  }

  Uri? _modelBase(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2 || segments.first.toLowerCase() != 'models') {
      return null;
    }
    return uri.replace(
      path: '/models/${segments[1]}/',
      query: '',
      fragment: '',
    );
  }

  Future<List<ModelRef>> videoModels(Video video) async {
    final pageUrl = video.pageUrl;
    if (pageUrl == null || pageUrl.trim().isEmpty) return const <ModelRef>[];

    final uri = config.baseUri.resolve(pageUrl);
    final document = html.parse(await _getDetailPage(uri));

    var anchors = document.querySelectorAll('.media-models a[href]');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('.media-info a[href*="/models/"]');
    }

    final models = <ModelRef>[];
    final seen = <String>{};
    for (final anchor in anchors) {
      final target = _resolveHttp(anchor.attributes['href'], uri);
      final base = target == null ? null : _modelBase(target);
      if (base == null || !seen.add(base.toString())) continue;

      var name = _collapse(anchor.text);
      if (name.isEmpty) name = _collapse(anchor.attributes['title'] ?? '');
      if (name.isEmpty) {
        name = base.pathSegments[1].replaceAll(RegExp(r'[-_]+'), ' ').trim();
      }
      if (name.isEmpty) continue;
      models.add(ModelRef(name: name, url: base.toString()));
    }
    return models;
  }

  Future<ModelPageResult> modelPage(ModelRef model, {int page = 1}) async {
    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
    final uri = page <= 1 ? base.resolve('videos/') : base.resolve('videos/$page/');

    final String body;
    try {
      body = await _get(uri);
    } on ScraperException catch (error) {
      if (page > 1 && error.statusCode == 404) {
        return const ModelPageResult(videos: <Video>[]);
      }
      rethrow;
    }

    final document = html.parse(body);
    return ModelPageResult(
      videos: _videosFrom(document, uri, config.cardSelector),
      profile: page <= 1 ? _modelProfile(document, uri, model) : null,
    );
  }

  String? _imageSource(dom.Element? image) {
    if (image == null) return null;
    const names = ['data-src', 'data-original', 'data-webp', 'src'];
    for (final name in names) {
      final value = image.attributes[name]?.trim();
      if (value != null && value.isNotEmpty && !value.startsWith('data:')) {
        return value;
      }
    }
    return null;
  }

  Future<List<AlbumRef>> modelAlbums(ModelRef model, {int page = 1}) async {
    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
    final uri = page <= 1 ? base.resolve('albums/') : base.resolve('albums/$page/');

    final String body;
    try {
      body = await _get(uri);
    } on ScraperException catch (error) {
      if (page > 1 && error.statusCode == 404) return const <AlbumRef>[];
      rethrow;
    }
    final albums = _albumsFrom(html.parse(body), uri, modelName: model.name);
    return albums;
  }

  List<AlbumRef> _albumsFrom(dom.Document document, Uri uri, {String? modelName}) {
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
      final anchor = card.localName == 'a' ? card : card.querySelector('a[href]');
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
      albums.add(AlbumRef(
        id: id,
        title: title,
        url: target.toString(),
        thumbnailUrl: _absoluteUrl(_imageSource(image), uri),
        modelName: modelName,
      ));
    }
    return albums;
  }

  Future<List<AlbumPhoto>> albumPhotos(AlbumRef album, {int chunk = 0}) async {
    final base = Uri.parse(album.url);
    final Uri uri;
    Map<String, String>? extra;
    if (chunk <= 0) {
      uri = base;
    } else {
      uri = base.replace(queryParameters: <String, String>{
        ...base.queryParameters,
        'mode': 'async',
        'function': 'get_block',
        'block_id': 'album_view_album_view',
        'load': 'more',
        'from': '$chunk',
      });
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
        return const <AlbumPhoto>[];
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
    return photos;
  }

  static String _photoId(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final match = RegExp(r'/sources/(.+?)/?$').firstMatch(path);
    return match?.group(1) ?? path;
  }

  ModelProfile _modelProfile(dom.Document document, Uri pageUri, ModelRef model) {
    String? name;
    String? image;

    void walk(Object? node) {
      if (node is List) {
        node.forEach(walk);
      } else if (node is Map) {
        final type = node['@type'];
        final isPerson = type == 'Person' || (type is List && type.contains('Person'));
        if (isPerson && name == null) {
          final rawName = node['name']?.toString().trim() ?? '';
          if (rawName.isNotEmpty) name = rawName;
          final raw = node['image'];
          String? candidate;
          if (raw is String) {
            candidate = raw;
          } else if (raw is List && raw.isNotEmpty) {
            final first = raw.first;
            candidate = first is Map ? first['url']?.toString() : first?.toString();
          } else if (raw is Map) {
            candidate = raw['url']?.toString();
          }
          image = _absoluteUrl(candidate, pageUri);
        }
        node.values.forEach(walk);
      }
    }

    final blocks = document.querySelectorAll('script[type="application/ld+json"]');
    for (final script in blocks) {
      try {
        walk(jsonDecode(script.text));
      } catch (_) {
      }
    }

    if (image == null) {
      for (final selector in const [
        'meta[property="og:image"]',
        'meta[name="twitter:image"]',
        'link[rel="image_src"]',
      ]) {
        final element = document.querySelector(selector);
        final value = element?.attributes['content'] ?? element?.attributes['href'];
        final url = _absoluteUrl(value, pageUri);
        if (url != null && !RegExp(r'logo|/static/', caseSensitive: false).hasMatch(url)) {
          image = url;
          break;
        }
      }
    }
    if (image == null) {
      for (final script in blocks) {
        final match = RegExp(r'"image"\s*:\s*"([^"]+)"').firstMatch(script.text);
        final url = _absoluteUrl(match?.group(1)?.replaceAll(r'\/', '/'), pageUri);
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
    return result.profile ?? ModelProfile(name: model.name);
  }

  Future<PeopleSearchResult> searchPeople(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const PeopleSearchResult(models: [], albums: []);

    final models = <String, ModelRef>{};
    final albums = <String, AlbumRef>{};

    final slugs = <String>{
      ScraperConfig._slugify(q),
      q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''),
    }..removeWhere((s) => s.isEmpty);
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
            models.putIfAbsent(
              ref.url,
              () => ModelRef(
                name: profile?.name ?? q,
                url: ref.url,
                imageUrl: profile?.imageUrl,
              ),
            );
          } on ScraperException {
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
        if (name.isEmpty) name = _collapse(anchor.querySelector('img')?.attributes['alt'] ?? '');
        if (name.isEmpty) name = base.pathSegments[1].replaceAll(RegExp(r'[-_]+'), ' ');
        models[base.toString()] = ModelRef(
          name: name,
          url: base.toString(),
          imageUrl: _absoluteUrl(_imageSource(anchor.querySelector('img')), uri),
        );
      }
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

    await Future.wait<void>([
      for (final model in sorted.take(3))
        () async {
          try {
            for (final album in await modelAlbums(model)) {
              albums.putIfAbsent(album.id, () => album);
            }
          } on ScraperException {
          }
        }(),
    ]);

    return PeopleSearchResult(
      models: sorted.take(20).toList(),
      albums: albums.values.toList(),
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
  static final RegExp _viewsRe =
      RegExp(r'(\d[\d,.]*\s*[KkMm]?)\s*views?\b', caseSensitive: false);
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
      return (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
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

    final match =
        RegExp(r'^(\d[\d.,\s\u00a0]*?)\s*([KkMmBb])?$').firstMatch(text);
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
      final raw = _text(element, config.likesSelector) ??
          element.attributes['data-rating'] ??
          element.attributes['data-likes'];
      final match = raw == null ? null : _percentRe.firstMatch(raw);
      if (match != null) likes = '${match.group(1)}%';
    }

    var duration = _durationRe
            .firstMatch(_iconText(element, config.durationIconSelector) ?? '')
            ?.group(1) ??
        '';
    if (duration.isEmpty) {
      duration = _durationRe
              .firstMatch(_text(element, config.durationSelector) ?? '')
              ?.group(1) ??
          '';
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
    final thumbnailRaw = image?.attributes['data-src'] ??
        image?.attributes['data-original'] ??
        image?.attributes['data-lazy-src'] ??
        image?.attributes['src'] ??
        element.querySelector('video[poster]')?.attributes['poster'];
    final thumbnail = _absoluteUrl(thumbnailRaw, pageUri);

    var title = (anchor?.attributes['title'] ??
            element.attributes['data-title'] ??
            element.querySelector(config.titleSelector)?.text ??
            image?.attributes['alt'] ??
            anchorText)
        .trim();
    title = _isPolluted(title) ? _cleanTitle(title) : _collapse(title);
    if (title.isEmpty) title = _cleanTitle(anchorText);
    if (title.isEmpty) title = _cleanTitle(cardText);
    if (title.isEmpty) return null;

    final id = element.attributes['data-id'] ??
        '${videoPage.host}${videoPage.path}${videoPage.hasQuery ? '?${videoPage.query}' : ''}';
    final directStream = _directStreamFromCard(element, pageUri);
    final previewUrl = _absoluteUrl(
          image?.attributes['data-preview'] ??
              element.querySelector('[data-preview]')?.attributes['data-preview'],
          pageUri,
        ) ??
        '';

    return Video(
      id: id,
      title: title,
      streamUrl: directStream ?? '',
      pageUrl: videoPage.toString(),
      previewUrl: previewUrl,
      thumbnailUrl: thumbnail,
      duration: duration,
      views: views,
      likes: likes,
      date: date,
      category: element.attributes['data-category'] ?? 'Video',
    );
  }

  String? _text(dom.Element element, String selector) {
    if (selector.trim().isEmpty) return null;
    return element.querySelector(selector)?.text.trim();
  }

  String? _directStreamFromCard(dom.Element element, Uri pageUri) {
    final raw = element.attributes['data-video-url'] ??
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
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      return uri.toString();
    } catch (_) {
      return null;
    }
  }

  String? _capture(String text, String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false, dotAll: true)
          .firstMatch(text)
          ?.group(1);
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

  ({String? best, bool needsDecoding}) _extractStreams(
    String body,
    dom.Document document,
    Uri base,
  ) {
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

    for (final node in document.querySelectorAll('video source[src], video[src]')) {
      final label = node.attributes['label'] ??
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

    return (
      best: unique.isEmpty ? null : unique.first.url,
      needsDecoding: needsDecoding,
    );
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
            _capture(body, config.detailTitlePattern) ??
            video.title;
    final descriptionNode = document.querySelector(config.descriptionSelector);
    final description =
        descriptionNode?.attributes['content']?.trim().isNotEmpty == true
            ? descriptionNode!.attributes['content']!.trim()
            : descriptionNode?.text.trim() ?? video.description;
    final thumbnail = _absoluteUrl(
          _capture(body, r"""preview_url1?\s*[:=]\s*["']([^"']+)["']""") ??
              _capture(body, config.previewPattern) ??
              document.querySelector('video[poster]')?.attributes['poster'],
          uri,
        ) ??
        video.thumbnailUrl;

    return video.copyWith(
      title: title.trim().isEmpty ? video.title : title.trim(),
      streamUrl: streamUrl,
      description: description,
      thumbnailUrl: thumbnail,
      pageUrl: uri.toString(),
    );
  }

  Future<List<Video>> related(Video video, {int limit = 6}) async {
    final pageUrl = video.pageUrl;
    if (pageUrl == null || pageUrl.isEmpty || config.relatedCardSelector.isEmpty) {
      return const <Video>[];
    }
    try {
      return (await list(config.baseUri.resolve(pageUrl), related: true))
          .where((item) => item.id != video.id)
          .take(limit < 0 ? 0 : limit)
          .toList();
    } catch (_) {
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
