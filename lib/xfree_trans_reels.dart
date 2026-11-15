import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:cupertino_http/cupertino_http.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'reel_favorites.dart';

const String _xfreeBase = 'https://www.xfree.com';
const String _xfreeUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 '
    'Mobile/15E148 Safari/604.1';
const int _maxXFreeResponseBytes = 8 * 1024 * 1024;

int _xfreeInt(dynamic value) {
  if (value is num && value.isFinite) return value.clamp(0, 2147483647).toInt();
  if (value is String) {
    final cleaned = value.replaceAll(',', '').trim();
    final direct = int.tryParse(cleaned);
    if (direct != null) return direct.clamp(0, 2147483647).toInt();
    final match = RegExp(r'^(\d+(?:\.\d+)?)\s*([kmb])?$', caseSensitive: false)
        .firstMatch(cleaned.toLowerCase());
    if (match != null) {
      final number = double.tryParse(match.group(1) ?? '');
      if (number != null && number.isFinite) {
        final multiplier = switch (match.group(2)) {
          'k' => 1000.0,
          'm' => 1000000.0,
          'b' => 1000000000.0,
          _ => 1.0,
        };
        return (number * multiplier).clamp(0, 2147483647).round();
      }
    }
  }
  return 0;
}

String? _xfreeString(dynamic value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.length > 8192 ? null : text;
}

String _xfreeDisplayValue(dynamic value) {
  if (value is String) return value.trim();
  if (value is num && value.isFinite) return value.toString();
  return '';
}

String? _xfreeAbsoluteUrl(dynamic value) {
  final raw = _xfreeString(value);
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  final host = uri?.host.toLowerCase() ?? '';
  if (uri == null ||
      !uri.hasAuthority ||
      host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !(host == 'xfree.com' || host.endsWith('.xfree.com'))) {
    return null;
  }
  return uri.toString();
}

Map<String, dynamic> _xfreeMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return <String, dynamic>{};
}

dynamic _xfreeUnwrap(dynamic decoded) {
  if (decoded is Map && decoded['body'] != null) return decoded['body'];
  return decoded;
}

class XFreeAccountProfile {
  const XFreeAccountProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    this.uid = '',
    this.bio = '',
    this.hitCount = 0,
    this.postLikeCount = 0,
    this.postViewCount = 0,
    this.postsUnlisted = 0,
    this.postsPublished = 0,
    this.followers = 0,
    this.following = 0,
    this.postsCount = 0,
    this.lastActive = '',
    this.lastPostDate = '',
  });

  final String id;
  final String uid;
  final String username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  final int hitCount;
  final int postLikeCount;
  final int postViewCount;
  final int postsUnlisted;
  final int postsPublished;
  final int followers;
  final int following;
  final int postsCount;
  final String lastActive;
  final String lastPostDate;

  factory XFreeAccountProfile.fromJson(Map<String, dynamic> json) {
    final avatar = _xfreeMap(json['avatarMedia']);
    final avatarName = _xfreeString(avatar['name']);
    return XFreeAccountProfile(
      id: '${json['id'] ?? ''}',
      uid: _xfreeString(json['uid']) ?? '',
      username: _xfreeString(json['username']) ?? '',
      displayName: _xfreeString(json['displayName']) ??
          _xfreeString(json['username']) ?? '',
      bio: _xfreeString(json['bio']) ?? '',
      avatarUrl: avatarName == null
          ? null
          : 'https://thumbs.xfree.com/avatar/medium/${Uri.encodeComponent(avatarName)}.png',
      hitCount: _xfreeInt(json['hitCount']),
      postLikeCount: _xfreeInt(json['postLikeCount']),
      postViewCount: _xfreeInt(json['postViewCount']),
      postsUnlisted: _xfreeInt(json['postsUnlisted']),
      postsPublished: _xfreeInt(json['postsPublished']),
      followers: _xfreeInt(json['followers']),
      following: _xfreeInt(json['following']),
      postsCount: _xfreeInt(json['postsCount']),
      lastActive: _xfreeDisplayValue(json['lastActive']),
      lastPostDate: _xfreeDisplayValue(json['lastPostDate']),
    );
  }
}

class XFreeAccountSnapshot {
  const XFreeAccountSnapshot({
    required this.profile,
    required this.pinnedPosts,
    required this.firstAuthorPosts,
    required this.authorRecommId,
  });

  final XFreeAccountProfile profile;
  final List<Map<String, dynamic>> pinnedPosts;
  final List<Map<String, dynamic>> firstAuthorPosts;
  final String authorRecommId;
}

/// XFree's Trans feed and account APIs. This repository is deliberately kept
/// separate from the legacy Reels provider and is selected only for Trans.
class XFreeTransReelsRepository {
  XFreeTransReelsRepository() : _client = _createClient();

  final http.Client _client;
  final Set<String> _seenPosts = <String>{};
  final List<Map<String, dynamic>> _pendingPosts = <Map<String, dynamic>>[];
  String? _categoryRecommId;
  bool _disposed = false;

  static http.Client _createClient() {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        return CupertinoClient.defaultSessionConfiguration();
      }
    } catch (_) {}
    return http.Client();
  }

  Map<String, String> _headers({String? referer, bool json = false}) => {
        'User-Agent': _xfreeUserAgent,
        'Accept': json
            ? 'application/json, text/plain, */*'
            : 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': referer ?? '$_xfreeBase/trans/',
        'Origin': _xfreeBase,
      };

  Future<String> _getBrowserText(Uri uri) async {
    final text = await XFreeWindowsBrowser.fetchText(uri);
    if (utf8.encode(text).length > _maxXFreeResponseBytes) {
      throw const FormatException('XFree browser response is too large.');
    }
    return text;
  }

  Future<String> _getText(Uri uri, {bool json = false}) async {
    if (_disposed) throw StateError('XFree repository is closed.');
    try {
      final response = await _client
          .get(uri, headers: _headers(json: json))
          .timeout(const Duration(seconds: 24));
      if (response.statusCode != 200) {
        throw HttpException('XFree returned HTTP ${response.statusCode}.', uri: uri);
      }
      if (response.bodyBytes.length > _maxXFreeResponseBytes) {
        throw const FormatException('XFree response is too large.');
      }
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (Platform.isWindows &&
          (text.contains('Just a moment') || text.contains('cf-chl-'))) {
        return _getBrowserText(uri);
      }
      return text;
    } catch (_) {
      // Windows' native HTTP fingerprint may be rejected by the edge server.
      // Retry through the same Chromium WebView2 profile used by the app.
      if (Platform.isWindows) return _getBrowserText(uri);
      rethrow;
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(_xfreeBase).replace(path: path, queryParameters: query);

  String _extractRecommId(String pageHtml) {
    final keyed = RegExp(
      r'''(?:recommId|recomm_id)\s*["']?\s*[:=]\s*["'](rec_[A-Za-z0-9_-]+)''',
      caseSensitive: false,
    ).firstMatch(pageHtml)?.group(1);
    final fallback = RegExp(r'rec_[A-Za-z0-9_-]{6,}').firstMatch(pageHtml)?.group(0);
    final value = keyed ?? fallback;
    if (value == null) {
      throw const FormatException('Could not find the Trans feed recommId in XFree /trans/.');
    }
    return value;
  }

  Future<String> _ensureCategoryRecommId() async {
    final existing = _categoryRecommId;
    if (existing != null) return existing;
    final categoryUri = _uri('/trans/');
    var page = await _getText(categoryUri);
    String id;
    try {
      id = _extractRecommId(page);
    } catch (_) {
      if (!Platform.isWindows) rethrow;
      page = await _getBrowserText(categoryUri);
      id = _extractRecommId(page);
    }
    _categoryRecommId = id;
    return id;
  }

  List<Map<String, dynamic>> _postsFrom(dynamic decoded) {
    final body = _xfreeUnwrap(decoded);
    if (body is List) {
      return body.whereType<Map>().map(_xfreeMap).toList(growable: false);
    }
    final map = _xfreeMap(body);
    final posts = map['posts'];
    if (posts is List) {
      return posts.whereType<Map>().map(_xfreeMap).toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  Future<List<Map<String, dynamic>>> _fetchNextPosts(
    String recommId, {
    int limit = 18,
  }) async {
    final uri = _uri('/api/rs/next/', <String, String>{
      'type': 'post',
      'recommId': recommId,
      'limit': '$limit',
    });
    final decoded = jsonDecode(await _getText(uri, json: true));
    final posts = _postsFrom(decoded);
    if (posts.isEmpty && decoded is Map && decoded['statusCode'] != null) {
      final status = _xfreeInt(decoded['statusCode']);
      if (status != 2 && status != 200) {
        throw const FormatException('XFree returned an invalid feed response.');
      }
    }
    return posts;
  }

  Future<List<ReelItem>> nextBatch(int amount) async {
    final recommId = await _ensureCategoryRecommId();
    final ready = <ReelItem>[];
    var fetchRounds = 0;
    while (ready.length < amount && fetchRounds < 5) {
      if (_pendingPosts.isEmpty) {
        fetchRounds++;
        final posts = await _fetchNextPosts(recommId, limit: 18);
        for (final post in posts) {
          final id = '${post['id'] ?? ''}'.trim();
          if (id.isNotEmpty && !_seenPosts.contains(id) &&
              !_pendingPosts.any((queued) => '${queued['id']}' == id)) {
            _pendingPosts.add(post);
          }
        }
        if (_pendingPosts.isEmpty) break;
      }

      final count = (amount - ready.length).clamp(1, 3).toInt();
      final group = _pendingPosts.take(count).toList(growable: false);
      _pendingPosts.removeRange(0, group.length);
      for (final post in group) {
        final id = '${post['id'] ?? ''}'.trim();
        if (id.isNotEmpty) _seenPosts.add(id);
      }
      // Resolve stream URLs from each /video?id= page. Keep concurrency low to
      // avoid flooding the source and to limit memory/network pressure.
      final resolved = await Future.wait(group.map(_postToReel));
      ready.addAll(resolved.whereType<ReelItem>());
    }
    return ready.take(amount).toList(growable: false);
  }

  Future<ReelItem?> _postToReel(Map<String, dynamic> post) async {
    final id = '${post['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final media = _xfreeMap(post['media']);
    final user = _xfreeMap(post['user']);
    final username = _xfreeString(user['username']) ?? '';
    final displayName = _xfreeString(user['displayName']) ?? username;
    final avatarMedia = _xfreeMap(user['avatarMedia']);
    final avatarName = _xfreeString(avatarMedia['name']);
    final avatarUrl = avatarName == null
        ? null
        : 'https://thumbs.xfree.com/avatar/medium/${Uri.encodeComponent(avatarName)}.png';
    final tagsRaw = post['tags'];
    final tags = <String>[
      if (tagsRaw is List)
        for (final tag in tagsRaw.take(24))
          if (tag is Map &&
              (_xfreeString(tag['tag']) ?? _xfreeString(tag['name'])) != null)
            (_xfreeString(tag['tag']) ?? _xfreeString(tag['name']))!
          else if (tag is String && _xfreeString(tag) != null)
            _xfreeString(tag)!,
    ];
    final detailsUri = _uri('/video', <String, String>{'id': id});
    try {
      var page = await _getText(detailsUri);
      var document = html.parse(page);
      String? readMeta(String name) => document
          .querySelector('meta[name="$name"]')
          ?.attributes['content'];
      var stream = _xfreeAbsoluteUrl(readMeta('twitter:player:stream'));
      if (stream == null && Platform.isWindows) {
        page = await _getBrowserText(detailsUri);
        document = html.parse(page);
        stream = _xfreeAbsoluteUrl(readMeta('twitter:player:stream'));
      }
      if (stream == null) return null;
      final thumb = _xfreeAbsoluteUrl(readMeta('twitter:image'));
      final seconds = _xfreeInt(media['duration'] ?? post['duration']);
      final views = _xfreeInt(post['views'] ?? post['viewCount'] ?? post['viewsCount']);
      final likes = _xfreeInt(post['likes'] ?? post['likeCount'] ?? post['likesCount']);
      return ReelItem(
        id: id,
        videoUrl: stream,
        downloadUrl: stream,
        mediaReferer: detailsUri.toString(),
        // media.name is a UUID used in the CDN path, not a display title.
        title: _xfreeString(post['title']) ??
            _xfreeString(post['name']) ??
            (username.isNotEmpty ? 'Video by @$username' : 'XFree video'),
        thumbUrl: thumb,
        avatarUrl: avatarUrl,
        author: username.isNotEmpty ? username : displayName,
        views: views,
        likes: likes,
        durationSec: seconds,
        tags: tags,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[XFREE] video $id could not be resolved: ${error.runtimeType}');
      return null;
    }
  }

  Future<XFreeAccountSnapshot> getAccountSnapshot(String username) async {
    final encoded = Uri.encodeComponent(username.trim());
    if (encoded.isEmpty) throw const FormatException('Account username is empty.');
    final profileJson = _xfreeMap(
      _xfreeUnwrap(jsonDecode(await _getText(_uri('/api/user/$encoded'), json: true))),
    );
    if (profileJson.isEmpty) throw const FormatException('XFree returned an empty profile.');
    final profile = XFreeAccountProfile.fromJson(profileJson);
    if (profile.id.isEmpty) throw const FormatException('XFree profile does not contain a user ID.');

    Future<dynamic> safeJson(Uri uri) async {
      try {
        return jsonDecode(await _getText(uri, json: true));
      } catch (error) {
        if (kDebugMode) debugPrint('[XFREE] optional account endpoint failed: ${error.runtimeType}');
        return null;
      }
    }

    final results = await Future.wait<dynamic>(<Future<dynamic>>[
      safeJson(_uri('/api/post/', <String, String>{
        'limit': '20',
        'userId': profile.id,
        'pinsOnly': '1',
      })),
      safeJson(_uri('/api/rs/author', <String, String>{
        'device': 'mobile',
        'limit': '20',
        'userId': profile.id,
      })),
    ], eagerError: false);

    final pinned = _postsFrom(results[0]);
    final authorBody = _xfreeMap(_xfreeUnwrap(results[1]));
    final authorPosts = _postsFrom(results[1]);
    final recommId = _xfreeString(authorBody['recommId']) ?? '';
    return XFreeAccountSnapshot(
      profile: profile,
      pinnedPosts: pinned,
      firstAuthorPosts: authorPosts,
      authorRecommId: recommId,
    );
  }

  Future<List<Map<String, dynamic>>> getAllAuthorPosts(
    XFreeAccountSnapshot account, {
    int maxBatches = 100,
  }) async {
    final posts = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final post in account.firstAuthorPosts) {
      final id = '${post['id'] ?? ''}';
      if (id.isNotEmpty && seen.add(id)) posts.add(post);
    }
    final recommId = account.authorRecommId;
    if (recommId.isEmpty) return posts;
    for (var batch = 0; batch < maxBatches; batch++) {
      final next = await _fetchNextPosts(recommId, limit: 20);
      var added = 0;
      for (final post in next) {
        final id = '${post['id'] ?? ''}';
        if (id.isEmpty || !seen.add(id)) continue;
        posts.add(post);
        added++;
      }
      if (added == 0) break;
      if (batch + 1 < maxBatches) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    return posts;
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}

/// Windows browser fallback for the initial HTML page and XFree JSON endpoints.
/// Other platforms use their native HTTP implementation (Cupertino on iOS).
class XFreeWindowsBrowser {
  static WebviewController? _controller;
  static Future<void>? _initializing;
  static Future<void> _queue = Future<void>.value();

  static Future<String> fetchText(Uri uri) {
    final completer = Completer<String>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _fetch(uri));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  static Future<String> _fetch(Uri uri) async {
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
    if (controller == null) throw const HttpException('XFree browser initialization failed.');
    await controller.loadUrl(uri.toString());
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final result = await controller.executeScript(
          '(()=>{const t=(document.body?.innerText||"").trim();'
          'if(t.startsWith("{")||t.startsWith("["))return t;'
          'return document.documentElement?.outerHTML||t;})()',
        );
        if (result is String && result.trim().isNotEmpty) {
          final text = result.trim();
          final isApi = uri.path.startsWith('/api/');
          final hasExpectedPayload = isApi
              ? text.startsWith('{') || text.startsWith('[')
              : uri.path == '/trans/'
                  ? text.contains('rec_')
                  : uri.path == '/video'
                      ? text.contains('twitter:player:stream')
                      : text.length > 400;
          if (hasExpectedPayload) return text;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }
    throw TimeoutException('XFree browser timed out.');
  }
}
