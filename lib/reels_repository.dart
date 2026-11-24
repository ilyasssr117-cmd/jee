import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'content_source.dart';
import 'reel_favorites.dart';
import 'models.dart';
import 'reel_seen_store.dart';
import 'xxx_follow_trans_reels.dart';

/// Reels data layer, extracted from reels_page.dart (Phase 7).
///
/// Owns the reels API client, the Windows/Android browser fallbacks
/// for endpoints that reject plain HTTP clients, response validation
/// and the seen-filtering batch logic. The page keeps only UI,
/// playback pooling and gestures. Public API is unchanged:
/// [ReelsRepository] with the same constructor and methods.
const String _kUserAgent = kReelUserAgent;

const int _kMaxRefetchTries = 4;

const String _kApiUrl = String.fromEnvironment(
  'REELS_API_URL',
  defaultValue: 'https://apiv2.tik.porn/getnextvideos',
);
const bool _kReelsSfwMode = bool.fromEnvironment(
  'REELS_SFW_MODE',
  defaultValue: false,
);

/// Shared HTTP client factory for reels media/API traffic
/// (Cupertino session on Apple platforms, default client elsewhere).
http.Client makeReelsHttpClient() {
  try {
    if (Platform.isIOS || Platform.isMacOS) {
      return CupertinoClient.defaultSessionConfiguration();
    }
  } catch (_) {}
  return http.Client();
}

/// Response parsing for the reels API, moved with the data layer.
String? _str(dynamic v) =>
    v is String && v.isNotEmpty && v.length <= 8192 ? v : null;

String _clipText(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

String? _url(dynamic v) {
  final s = _str(v);
  if (s == null) return null;
  final uri = Uri.tryParse(s);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.scheme == 'http' || uri.scheme == 'https' ? s : null;
}

String _titleOf(Map video) {
  final parsed = video['video_text']?['user_display_video_title']?['default']
      ?['parsed_text'];
  if (_str(parsed) != null) return _clipText(parsed as String, 240);
  return _clipText(_str(video['action_name']) ?? '', 240);
}

int _countOf(dynamic value) {
  if (value is num) {
    return value.clamp(0, 2147483647).toInt();
  }
  if (value is Map) {
    for (final key in const [
      'count',
      'total',
      'value',
      'like_count',
      'likes_count',
      'formatted',
      'display',
    ]) {
      if (!value.containsKey(key)) continue;
      final parsed = _countOf(value[key]);
      if (parsed > 0) return parsed;
    }
    return 0;
  }
  if (value is! String) return 0;
  final text = value.trim().toLowerCase().replaceAll(',', '');
  if (text.isEmpty) return 0;
  final match = RegExp(
    r'^(\d+(?:\.\d+)?)\s*([kmb])?\s*(?:likes?)?$',
  ).firstMatch(text);
  if (match == null) return 0;
  final number = double.tryParse(match.group(1) ?? '');
  if (number == null || !number.isFinite || number < 0) return 0;
  final multiplier = switch (match.group(2)) {
    'k' => 1000.0,
    'm' => 1000000.0,
    'b' => 1000000000.0,
    _ => 1.0,
  };
  return (number * multiplier).clamp(0, 2147483647).round();
}

int _likesOf(Map video) {
  const keys = [
    'like_count',
    'likes_count',
    'likeCount',
    'likesCount',
    'likes',
    'like',
    'total_likes',
    'totalLikes',
    'favorite_count',
    'favorites_count',
    'favourite_count',
    'upvote_count',
    'thumbs_up_count',
  ];
  for (final source in [
    video,
    video['statistics'],
    video['stats'],
    video['engagement'],
    video['counts'],
    video['video_statistics'],
    video['video_stats'],
    video['engagement_stats'],
    video['metadata'],
    video['meta'],
  ]) {
    if (source is! Map) continue;
    for (final key in keys) {
      if (!source.containsKey(key) || source[key] == null) continue;
      final parsed = _countOf(source[key]);
      if (parsed > 0) return parsed;
    }
  }
  return 0;
}

List<String> _tagsOf(Map video) {
  final raw = video['tags'];
  if (raw is! List) return const [];
  return [
    for (final t in raw.take(24))
      if (t is Map && _str(t['name']) != null)
        _clipText(t['name'] as String, 64),
  ];
}

List<ReelItem> parseReels(dynamic body) {
  if (body is! Map || body['data'] is! List) return const [];
  final out = <ReelItem>[];
  for (final raw in (body['data'] as List).take(48)) {
    if (raw is! Map) continue;
    final mp4 = _url(raw['mp4_url']);
    final hls = _url(raw['hls_url']);
    final url = mp4 ?? hls;
    if (url == null) continue;
    out.add(
      ReelItem(
        id: _clipText('${raw['video_id'] ?? url}', 256),
        videoUrl: url,
        fallbackUrl: mp4 != null ? hls : null,
        downloadUrl: _url(raw['download_url']),
        title: _titleOf(raw),
        thumbUrl: _url(raw['poster_url']) ?? _url(raw['thumbnail_url']),
        avatarUrl: _url(raw['user_avatar']),
        author: _clipText(_str(raw['user_name']) ?? '', 100),
        views: raw['view_count'] is num
            ? (raw['view_count'] as num).clamp(0, 2147483647).toInt()
            : 0,
        likes: _likesOf(raw),
        durationSec: raw['duration'] is num
            ? (raw['duration'] as num).clamp(0, 86400).toInt()
            : 0,
        tags: _tagsOf(raw),
      ),
    );
  }
  return out;
}

class _WindowsReelsBrowser {
  static WebviewController? _controller;
  static Future<void>? _initializing;
  static Future<void> _queue = Future<void>.value();

  static Future<List<ReelItem>> fetch(Uri uri) {
    final result = Completer<List<ReelItem>>();
    _queue = _queue.then((_) async {
      try {
        try {
          result.complete(await _fetch(uri));
        } catch (_) {
          await _reset();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          result.complete(await _fetch(uri));
        }
      } catch (error, stackTrace) {
        if (kDebugMode) {
        }
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  static Future<void> _reset() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (_) {}
  }

  static Future<List<ReelItem>> _fetch(Uri uri) async {
    var controller = _controller;
    if (controller == null) {
      final initializing = _initializing ??= () async {
        final browser = WebviewController();
        await browser.initialize();
        await browser.setSize(const Size(1280, 720));
        await browser.setDevToolsEnabled(false);
        _controller = browser;
      }();
      try {
        await initializing.timeout(const Duration(seconds: 20));
      } finally {
        if (identical(_initializing, initializing)) _initializing = null;
      }
      controller = _controller;
    }
    if (controller == null) {
      throw const HttpException('Windows browser could not be initialized.');
    }

    await controller.loadUrl(uri.toString());
    final deadline = DateTime.now().add(const Duration(seconds: 24));
    while (DateTime.now().isBefore(deadline)) {
      dynamic content;
      try {
        content = await controller.executeScript(
          'document.body ? document.body.innerText : ""',
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        continue;
      }
      if (content is String) {
        final text = content.trim();
        if (text.startsWith('{') || text.startsWith('[')) {
          final decoded = jsonDecode(text);
          if (decoded is Map &&
              decoded['code'] != null &&
              decoded['code'] != 200) {
            throw const FormatException(
                'Reels service returned an error response.');
          }
          return parseReels(decoded);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw TimeoutException('Windows browser timed out fetching Reels.');
  }
}

class _AndroidReelsBrowser {
  static const MethodChannel _channel =
      MethodChannel('com.tv.watch_tube/reels_browser');

  static Future<List<ReelItem>> fetch(Uri uri) async {
    final body = await _channel.invokeMethod<String>('fetchReels', {
      'url': uri.toString(),
      'headers': const {
        'Accept': 'application/json',
        'Origin': 'https://tik.porn',
        'Referer': 'https://tik.porn/',
      },
    }).timeout(const Duration(seconds: 28));
    if (body == null || body.isEmpty) {
      throw const HttpException('Android browser returned an empty response.');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['code'] != null && decoded['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(decoded);
  }
}

class _ReelsMethodNotAllowed implements Exception {
  const _ReelsMethodNotAllowed();
}

class _ReelsHttpFailure implements Exception {
  const _ReelsHttpFailure(this.statusCode, {this.retryAfter});
  final int statusCode;
  final Duration? retryAfter;
}

Uri _validatedReelsApiUri() {
  final uri = Uri.tryParse(_kApiUrl);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'REELS_API_URL must be a valid HTTP or HTTPS URL.',
    );
  }
  return uri;
}

class ReelsRepository {
  ReelsRepository({
    required this.source,
    SeenReelLookup? findPreviouslySeenIds,
  })  : _findPreviouslySeenIds = findPreviouslySeenIds,
        _transRepository = XxxFollowTransReelsRepository(
          findPreviouslySeenIds:
              source == ContentSource.trans ? findPreviouslySeenIds : null,
        );

  final ContentSource source;
  final SeenReelLookup? _findPreviouslySeenIds;
  final XxxFollowTransReelsRepository _transRepository;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final http.Client _client = makeReelsHttpClient();

  static final Uri _api = _validatedReelsApiUri();
  static const Map<String, String> _headers = {
    'User-Agent': _kUserAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Origin': 'https://tik.porn',
    'Referer': 'https://tik.porn/',
  };

  Future<List<ReelItem>> _post(int amount) async {
    final req = http.Request('POST', _api)
      ..headers.addAll(_headers)
      ..bodyBytes = utf8.encode(
        jsonEncode({
          'amount': amount,
          'filter': [],
          'sfw_mode': _kReelsSfwMode ? 1 : 0,
          'forcerand': false,
          'first_chunk': false,
        }),
      );
    final res = await _sendBounded(req);
    return _decode(res);
  }

  Future<List<ReelItem>> _getOnce() async {
    if (Platform.isWindows) return _WindowsReelsBrowser.fetch(_api);
    if (Platform.isAndroid) return _AndroidReelsBrowser.fetch(_api);
    final req = http.Request('GET', _api)
      ..headers.addAll(const {
        'User-Agent': _kUserAgent,
        'Accept': 'application/json',
        'Origin': 'https://tik.porn',
        'Referer': 'https://tik.porn/',
      });
    return _decode(await _sendBounded(req));
  }

  Future<http.Response> _sendBounded(http.Request request) async {
    const maxResponseBytes = 6 * 1024 * 1024;
    final response =
        await _client.send(request).timeout(const Duration(seconds: 20));
    if (response.contentLength != null &&
        response.contentLength! > maxResponseBytes) {
      await response.stream.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
      throw const FormatException('Reels response is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 24),
    )) {
      received += chunk.length;
      if (received > maxResponseBytes) {
        throw const FormatException('Reels response is too large.');
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  Duration? _retryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds.clamp(0, 6).toInt());
    }
    DateTime? date = DateTime.tryParse(value.trim());
    if (date == null) {
      try {
        date = HttpDate.parse(value.trim());
      } catch (_) {}
    }
    if (date == null) return null;
    final remaining = date.difference(DateTime.now());
    if (remaining.isNegative) return Duration.zero;
    return remaining > const Duration(seconds: 6)
        ? const Duration(seconds: 6)
        : remaining;
  }

  List<ReelItem> _decode(http.Response res) {
    if (res.statusCode == 405 || res.statusCode == 501) {
      throw const _ReelsMethodNotAllowed();
    }
    if (res.statusCode != 200) {
      throw _ReelsHttpFailure(
        res.statusCode,
        retryAfter: _retryAfter(res.headers['retry-after']),
      );
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is Map && json['code'] != null && json['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(json);
  }

  Future<List<ReelItem>> _fetch(int amount) async {
    if (Platform.isWindows) {
      try {
        final resolved = await _getWithWindowsCurl();
        if (resolved.isNotEmpty) return resolved;
      } catch (error) {
        if (kDebugMode) {
        }
      }
    }
    try {
      final resolved = await _getOnce();
      if (resolved.isNotEmpty) return resolved;
    } catch (_) {}

    const retryableStatuses = <int>{408, 425, 429, 500, 502, 503, 504};
    for (var attempt = 0; attempt < 2; attempt++) {
      Duration? retryAfter;
      try {
        return await _post(amount);
      } on _ReelsMethodNotAllowed {
        return _getOnce();
      } on _ReelsHttpFailure catch (error) {
        if (!retryableStatuses.contains(error.statusCode) || attempt == 1) {
          rethrow;
        }
        retryAfter = error.retryAfter;
      } on SocketException {
        if (attempt == 1) rethrow;
      } on HandshakeException {
        if (attempt == 1) rethrow;
      } on http.ClientException {
        if (attempt == 1) rethrow;
      } on TimeoutException {
        if (attempt == 1) rethrow;
      }
      await Future<void>.delayed(
        retryAfter ?? Duration(milliseconds: 500 * (attempt + 1)),
      );
    }
    return _post(amount);
  }

  Future<List<ReelItem>> _getWithWindowsCurl() async {
    final result = await Process.run(
      'curl.exe',
      [
        '--fail',
        '--location',
        '--silent',
        '--show-error',
        '--max-time',
        '20',
        '--max-filesize',
        '${6 * 1024 * 1024}',
        '-H',
        'User-Agent: $_kUserAgent',
        '-H',
        'Accept: application/json',
        '-H',
        'Origin: https://tik.porn',
        '-H',
        'Referer: https://tik.porn/',
        _api.toString(),
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 22));

    if (result.exitCode != 0) {
      throw HttpException('curl.exe exited with code ${result.exitCode}.');
    }
    final body = result.stdout as String;
    if (utf8.encode(body).length > 6 * 1024 * 1024) {
      throw const FormatException('Reels response is too large.');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['code'] != null && decoded['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(decoded);
  }

  Future<List<ReelItem>> nextBatch(int amount) async {
    if (source == ContentSource.trans) {
      return _transRepository.nextBatch(amount);
    }
    final fresh = <ReelItem>[];
    var emptyRounds = 0;
    var rounds = 0;
    while (fresh.length < amount &&
        rounds < 4 &&
        emptyRounds < _kMaxRefetchTries) {
      rounds++;
      final fetched = await _fetch(amount - fresh.length);
      final persistedSeen = _findPreviouslySeenIds == null || fetched.isEmpty
          ? const <String>{}
          : await _findPreviouslySeenIds(fetched.expand((item) => [
                item.id,
                ReelSeenStore.urlKey(item.videoUrl),
              ]).where((key) => key.isNotEmpty));
      var added = 0;
      for (final item in fetched) {
        final idKey = 'id:${item.id}';
        final urlKey = 'url:${item.videoUrl}';
        if (_seen.contains(idKey) || _seen.contains(urlKey)) continue;
        _seen
          ..add(idKey)
          ..add(urlKey);
        if (persistedSeen.contains(item.id) ||
            persistedSeen.contains(ReelSeenStore.urlKey(item.videoUrl))) {
          continue;
        }
        fresh.add(item);
        added++;
      }
      while (_seen.length > 1200) {
        _seen.remove(_seen.first);
      }
      emptyRounds = added == 0 ? emptyRounds + 1 : 0;
    }
    return fresh;
  }

  Future<XxxFollowAccountSnapshot> getXxxFollowAccount(String username) =>
      _transRepository.getAccountSnapshot(username);

  Future<XxxFollowCommentsPage> getXxxFollowPostComments(
    String postId, {int offset = 0}
  ) => _transRepository.getPostComments(postId, offset: offset);

  bool hasMoreXxxFollowCreatorPages(String username) =>
      _transRepository.hasMoreCreatorPosts(username);

  bool get hasMoreTransPages =>
      source == ContentSource.trans && _transRepository.hasMoreItems;

  Future<List<Map<String, dynamic>>> getMoreXxxFollowCreatorPosts(
    XxxFollowAccountSnapshot account, {
    int maxPages = 8,
  }) => _transRepository.getMoreCreatorPosts(
        account,
        maxPages: maxPages,
      );

  void dispose() {
    _client.close();
    _transRepository.dispose();
  }
}

String safeReelFileToken(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

