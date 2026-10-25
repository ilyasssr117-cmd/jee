import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'models.dart';

/// HTML catalogue configuration for a source you own or are authorized to use.
/// Selectors and paths are configurable because each website has its own markup.
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
    // Fallbacks only: the icon selectors below are tried first.
    this.durationSelector = '.duration, [data-duration]',
    this.viewsSelector = '.views, [data-views]',
    // The number sits in the *parent* of an icon element, e.g.
    // <li><i class="icon-view"></i> 12.3K</li>
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

  /// A card is a video only if its link path matches this pattern.
  /// Leave empty to accept every link.
  final String videoPathPattern;

  /// Cards whose link path matches this are skipped (photo albums, galleries).
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
    // Most catalogue sites omit the page number on page one and use /2/, /3/…
    // for later pages. Keep query-parameter templates configurable too.
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

/// Fetches and parses HTML pages. It does not run JavaScript or bypass
/// encrypted, authenticated, DRM-protected, or otherwise protected streams.
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

  Future<String> _get(Uri uri) async {
    ScraperException? lastError;
    // One automatic retry for network hiccups and 5xx responses.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _getOnce(uri);
      } on ScraperException catch (error) {
        final status = error.statusCode;
        if (status != null && status < 500) rethrow; // 4xx: retrying is useless.
        lastError = error;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw lastError ?? const ScraperException('The source could not be read.');
  }

  Future<String> _getOnce(Uri uri) async {
    try {
      debugPrint('[SCRAPER] GET $uri');
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(config.timeout);
      debugPrint('[SCRAPER] HTTP ${response.statusCode} from $uri');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ScraperException(
          'Source request failed with HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      // `response.body` falls back to Latin-1 when the server omits a charset,
      // which garbles non-ASCII titles. Decode as UTF-8 unless told otherwise.
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
      debugPrint('[SCRAPER] Request failed for $uri: $error');
      throw ScraperException('Could not reach the video source: $error');
    }
  }

  Future<List<Video>> home({int page = 0}) {
    return list(page == 0 ? config.homeUri() : config.pageUri(page));
  }

  Future<List<Video>> search(String query, {int page = 1}) {
    if (query.trim().isEmpty) return Future.value(const <Video>[]);
    return list(config.searchUri(query, page));
  }

  Future<List<Video>> category(String slug, {int page = 1}) {
    return list(config.categoryUri(slug, page));
  }

  Future<List<Video>> list(Uri uri, {bool related = false}) async {
    final body = await _get(uri);
    final document = html.parse(body);
    final selector = related ? config.relatedCardSelector : config.cardSelector;
    if (selector.trim().isEmpty) return const <Video>[];

    final videos = <Video>[];
    final seen = <String>{};
    final cards = document.querySelectorAll(selector);
    debugPrint('[SCRAPER] Selector "$selector" matched ${cards.length} cards at $uri');
    for (final element in cards) {
      try {
        final video = _parseCard(element, uri);
        if (video == null || video.title.isEmpty || !seen.add(video.id)) {
          continue;
        }
        videos.add(video);
      } catch (error) {
        // Ignore malformed cards without throwing away valid cards on the page.
        debugPrint('[SCRAPER] Skipped an invalid video card: $error');
      }
    }
    debugPrint(
      '[SCRAPER] Parsed ${videos.length} videos from $uri '
      '(${cards.length - videos.length} cards skipped: albums / duplicates)',
    );
    return videos;
  }

  // ---- Card parsing -------------------------------------------------------

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

  /// Photo albums, galleries etc. use the same card markup as videos, so the
  /// link decides: it must look like a video page and must not look like an
  /// album.
  bool _isVideoUri(Uri uri) {
    final path = uri.path;
    final video = _videoPathRe;
    if (video != null && !video.hasMatch(path)) return false;
    final excluded = _excludePathRe;
    if (excluded != null && excluded.hasMatch(path)) return false;
    return true;
  }

  /// Text that still contains the "99%", views and age fragments of a card.
  static bool _isPolluted(String text) =>
      _leadingLikeRe.hasMatch(text) || _viewsRe.hasMatch(text);

  /// Removes like %, duration, views and "30 seconds ago" from card text,
  /// leaving only the title.
  static String _cleanTitle(String text) {
    var title = text.replaceFirst(RegExp(r'^\s*\d{1,3}\s*%\s*'), '');
    final duration = _durationRe.firstMatch(title)?.group(0);
    if (duration != null) title = title.replaceFirst(duration, '');
    title = title.replaceAll(_viewsRe, '').replaceAll(_ageRe, '');
    return _collapse(title);
  }

  /// Text of the element that holds an icon, e.g. for
  /// `<li><i class="icon-view"></i> 12.3K</li>` the result is `12.3K`.
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

  /// Turns whatever the site prints into a short label:
  /// `1,234` -> `1.2K views`, `2.5M` -> `2.5M views`, `812` -> `812 views`.
  /// Returns '' when the text doesn't look like a view count.
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
      // "1.2K" or "1,2K": the separator is a decimal point.
      final value = double.tryParse(number.replaceAll(',', '.'));
      return value == null ? '' : '${_compactNumber(value)}$suffix views';
    }

    // Plain digits: "1,234" / "1.234" / "1 234" use the separator for thousands.
    final count = int.tryParse(number.replaceAll(RegExp(r'[^\d]'), ''));
    if (count == null) return '';
    if (count >= 1000000000) return '${_compactNumber(count / 1e9)}B views';
    if (count >= 1000000) return '${_compactNumber(count / 1e6)}M views';
    if (count >= 1000) return '${_compactNumber(count / 1e3)}K views';
    return count == 1 ? '1 view' : '$count views';
  }

  Video? _parseCard(dom.Element element, Uri pageUri) {
    // 1. Find the link that really is a video page (skips albums).
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

    // 2. Text of the card: the link text first, the whole card as fallback.
    final anchorText = _collapse(anchor?.text ?? '');
    final cardText = _collapse(element.text);
    final texts = <String>[anchorText, cardText];

    // Like percentage, e.g. "99%" at the start of the link text.
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

    // Duration, e.g. "9:00" or "1:12:35": icon first, then looser fallbacks.
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

    // Albums have no duration and show a photo count instead.
    if (duration.isEmpty && _photosRe.hasMatch(cardText)) return null;

    // Views: the text next to the "view" icon is the source of truth.
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

    // Upload date / age, e.g. "2 months ago".
    final date = _collapse(_iconText(element, config.dateIconSelector) ?? '');

    // 3. Image and title.
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
    // KVS-style cards carry the preview clip as data-preview on the <img>.
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

  // ---- Stream resolution --------------------------------------------------

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

  /// Only things a player can really open: a media extension, an HLS/DASH
  /// manifest, or a KVS-style `/get_file/` endpoint. Images, scripts, embed
  /// pages and API URLs are rejected.
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

  /// Collects every plausible stream URL on a detail page and picks the best:
  /// real videos before previews, then the highest quality up to 1080p (4K is
  /// ranked just below it because older phones may not decode it smoothly).
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
      // KVS "function/0/<url>" needs a licence-code transform: unsupported.
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

    // 1. Player variables: video_url, video_alt_url, video_alt_url2, ...
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

    // 2. <video> / <source> tags.
    for (final node in document.querySelectorAll('video source[src], video[src]')) {
      final label = node.attributes['label'] ??
          node.attributes['title'] ??
          node.attributes['res'] ??
          node.attributes['size'] ??
          node.attributes['data-res'] ??
          '';
      add(node.attributes['src'], 1, label: label);
    }

    // 3. Open Graph / Twitter player metadata.
    for (final selector in const [
      'meta[property="og:video"]',
      'meta[property="og:video:url"]',
      'meta[property="og:video:secure_url"]',
      'meta[name="twitter:player:stream"]',
    ]) {
      add(document.querySelector(selector)?.attributes['content'], 2);
    }

    // 4. JSON-LD contentUrl.
    for (final value in _captureAll(body, r'"contentUrl"\s*:\s*"([^"]+)"')) {
      add(value, 3);
    }

    // 5. The configurable pattern: every match, kept only if it looks playable.
    for (final value in _captureAll(body, config.streamUrlPattern)) {
      add(value, 4);
    }

    // 6. Last resort: any media-looking URL in the page source.
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

    for (final c in unique) {
      debugPrint(
        '[SCRAPER] stream candidate rank=${c.rank} q=${c.quality} '
        'preview=${c.preview} ${c.url}',
      );
    }
    return (
      best: unique.isEmpty ? null : unique.first.url,
      needsDecoding: needsDecoding,
    );
  }

  /// Resolves a catalogue page to a direct stream only when one is exposed in
  /// the page HTML. It does not bypass protected/encrypted player formats.
  Future<Video> resolveForPlayback(Video video) async {
    if (video.streamUrl.trim().isNotEmpty) return video;
    final pageUrl = video.pageUrl;
    if (pageUrl == null || pageUrl.trim().isEmpty) {
      throw const ScraperException('This item has no detail-page URL.');
    }

    final uri = config.baseUri.resolve(pageUrl);
    final body = await _get(uri);
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

    // Prefer the page's own title over generic `title: '...'` script matches.
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

class _StreamCandidate {
  const _StreamCandidate(
    this.url, {
    required this.rank,
    required this.order,
    required this.quality,
    required this.preview,
  });

  final String url;

  /// Where it was found (lower = more trustworthy source).
  final int rank;

  /// Discovery order, used as the final tie-break.
  final int order;
  final int quality;
  final bool preview;

  /// Higher is better. Unknown quality sorts below any known one; 4K sorts just
  /// under 1080p so older phones are not handed streams they may not decode.
  int get score => quality <= 0 ? 1 : (quality > 1080 ? 1000 : quality);
}
