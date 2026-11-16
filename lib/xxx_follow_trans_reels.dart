import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'reel_favorites.dart';

const String _xxxFollowBaseUrl = 'https://www.xxxfollow.com/';
const String _xxxFollowUserAgent = kReelUserAgent;
const int _maxHtmlBytes = 12 * 1024 * 1024;

String? _stringValue(dynamic value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > 8192) return null;
  return text;
}

int _intValue(dynamic value) {
  if (value is num && value.isFinite) {
    return value.clamp(0, 2147483647).toInt();
  }
  if (value is String) {
    final parsed = int.tryParse(value.replaceAll(',', '').trim());
    if (parsed != null) return parsed.clamp(0, 2147483647).toInt();
  }
  return 0;
}

int? _optionalIntValue(dynamic value) {
  if (value == null) return null;
  if (value is num && value.isFinite) {
    return value.clamp(0, 2147483647).toInt();
  }
  if (value is String) {
    final parsed = int.tryParse(value.replaceAll(',', '').trim());
    if (parsed != null) return parsed.clamp(0, 2147483647).toInt();
  }
  return null;
}

Map<String, dynamic> _mapValue(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry('$key', value));
  }
  return <String, dynamic>{};
}

String? _siteUrl(dynamic raw, {required Uri baseUri}) {
  final text = _stringValue(raw);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  final baseHost = baseUri.host.startsWith('www.')
      ? baseUri.host.substring(4)
      : baseUri.host;
  if (uri == null ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.scheme != 'https' ||
      !(uri.host == baseHost || uri.host.endsWith('.$baseHost'))) {
    return null;
  }
  return uri.toString();
}

class XxxFollowCreatorProfile {
  const XxxFollowCreatorProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.gender,
    required this.createdAt,
    required this.isStreaming,
    this.avatarUrl,
    this.coverPictureUrl,
    this.coverVideoUrl,
    this.bio,
    this.followersCount,
    this.followingCount,
    this.postsCount,
    this.likesCount,
  });

  final String id;
  final String username;
  final String displayName;
  final String gender;
  final String createdAt;
  final bool isStreaming;
  final String? avatarUrl;
  final String? coverPictureUrl;
  final String? coverVideoUrl;
  final String? bio;
  final int? followersCount;
  final int? followingCount;
  final int? postsCount;
  final int? likesCount;

  factory XxxFollowCreatorProfile.fromJson(
    Map<String, dynamic> json, {
    required Uri baseUri,
  }) {
    final username = _stringValue(json['username']) ?? '';
    return XxxFollowCreatorProfile(
      id: '${json['id'] ?? ''}',
      username: username,
      displayName: _stringValue(json['display_name']) ?? username,
      gender: _stringValue(json['gender']) ?? '',
      createdAt: _stringValue(json['created_at']) ?? '',
      isStreaming: json['is_streaming'] == true,
      avatarUrl: _siteUrl(
        json['public_avatar_url'] ?? json['fans_avatar_url'],
        baseUri: baseUri,
      ),
      coverPictureUrl: _siteUrl(
        json['public_cover_picture_url'],
        baseUri: baseUri,
      ),
      coverVideoUrl: _siteUrl(
        json['public_cover_video_url'],
        baseUri: baseUri,
      ),
      bio: _stringValue(json['bio'] ?? json['biography'] ?? json['about']),
      followersCount: _optionalIntValue(
        json['followers_count'] ?? json['follower_count'] ?? json['followers'],
      ),
      followingCount: _optionalIntValue(
        json['following_count'] ?? json['followings_count'] ?? json['following'],
      ),
      postsCount: _optionalIntValue(
        json['posts_count'] ?? json['post_count'] ?? json['postsCount'],
      ),
      likesCount: _optionalIntValue(
        json['likes_count'] ?? json['post_like_count'] ?? json['like_count'],
      ),
    );
  }
}

class XxxFollowAccountSnapshot {
  const XxxFollowAccountSnapshot({
    required this.profile,
    required this.firstAuthorPosts,
  });

  final XxxFollowCreatorProfile profile;
  final List<Map<String, dynamic>> firstAuthorPosts;
}

class XxxFollowPageData {
  const XxxFollowPageData({
    required this.page,
    required this.gender,
    required this.posts,
    required this.nextUri,
  });

  final int page;
  final String gender;
  final List<Map<String, dynamic>> posts;
  final Uri? nextUri;
}

/// Parses the server-rendered state present in the HTML returned by
/// https://www.xxxfollow.com/?page=N. The supplied page uses
/// window.__PRELOAD_STATE__, not XFree's recommId/JSON API.
class XxxFollowTransParser {
  const XxxFollowTransParser._();

  static Map<String, dynamic> _extractPreloadState(String source) {
    const marker = 'window.__PRELOAD_STATE__';
    final markerIndex = source.indexOf(marker);
    if (markerIndex < 0) {
      throw const FormatException(
        'XXXFollow did not include window.__PRELOAD_STATE__ in its HTML.',
      );
    }

    final equalsIndex = source.indexOf('=', markerIndex + marker.length);
    if (equalsIndex < 0) {
      throw const FormatException('XXXFollow preload state assignment is invalid.');
    }
    final start = source.indexOf('{', equalsIndex + 1);
    if (start < 0) {
      throw const FormatException('XXXFollow preload state JSON is missing.');
    }

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < source.length; index++) {
      final char = source.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == 0x5c) {
          escaped = true;
        } else if (char == 0x22) {
          inString = false;
        }
        continue;
      }
      if (char == 0x22) {
        inString = true;
      } else if (char == 0x7b) {
        depth++;
      } else if (char == 0x7d) {
        depth--;
        if (depth == 0) {
          final decoded = jsonDecode(source.substring(start, index + 1));
          final state = _mapValue(decoded);
          if (state.isEmpty) {
            throw const FormatException('XXXFollow preload state is empty.');
          }
          return state;
        }
      }
    }

    throw const FormatException('XXXFollow preload state JSON is incomplete.');
  }

  static Uri? _readNextUri(
    Map<String, dynamic> state, {
    required String source,
    required Uri pageUri,
  }) {
    String? rawNext;
    for (final entry in state.entries) {
      if (!entry.key.startsWith('pagination-home-')) continue;
      final pagination = _mapValue(entry.value);
      rawNext = _stringValue(pagination['next']);
      if (rawNext != null) break;
    }

    rawNext ??= RegExp(
      r'''<link[^>]+rel=["']next["'][^>]+href=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(source)?.group(1);

    if (rawNext == null) return null;
    final next = Uri.tryParse(rawNext);
    final resolved = next != null && next.hasAuthority
        ? next
        : pageUri.resolve(rawNext);
    const allowedHosts = <String>{'xxxfollow.com', 'www.xxxfollow.com'};
    if (resolved.scheme != 'https' ||
        (!allowedHosts.contains(resolved.host) &&
            resolved.host != pageUri.host)) {
      return null;
    }
    return resolved;
  }

  static XxxFollowPageData parsePage(
    String source, {
    Uri? pageUri,
  }) {
    final uri = pageUri ?? Uri.parse(_xxxFollowBaseUrl);
    final state = _extractPreloadState(source);
    final home = _mapValue(state['list-home']);
    if (home.isEmpty) {
      throw const FormatException(
        'XXXFollow HTML did not contain the home feed state.',
      );
    }

    final gender = _stringValue(home['genders']) ?? '';
    if (gender != 't') {
      throw FormatException(
        'XXXFollow returned gender "$gender" instead of the Trans feed. '
        'Check the genders=t cookie.',
      );
    }

    final rawPosts = home['list'];
    if (rawPosts is! List) {
      throw const FormatException('XXXFollow home feed list is missing.');
    }
    final posts = rawPosts
        .whereType<Map>()
        .map(_mapValue)
        .toList(growable: false);
    final page = _intValue(home['page']);

    return XxxFollowPageData(
      page: page,
      gender: gender,
      posts: posts,
      nextUri: _readNextUri(state, source: source, pageUri: uri),
    );
  }

  static List<ReelItem> toReels(
    XxxFollowPageData page, {
    required Uri baseUri,
  }) {
    final output = <ReelItem>[];
    for (final row in page.posts) {
      final post = _mapValue(row['post']);
      final user = _mapValue(post['user']);
      final username = _stringValue(user['username']) ?? '';
      final displayName = _stringValue(user['display_name']) ?? username;
      final mediaList = post['media'];
      if (mediaList is! List) continue;

      for (final rawMedia in mediaList) {
        final media = _mapValue(rawMedia);
        if (media['type'] != 'video') continue;

        final videoUrl = _siteUrl(
          media['fhd_url'] ?? media['url'] ?? media['sd_url'] ?? media['uhd_url'],
          baseUri: baseUri,
        );
        if (videoUrl == null) continue;

        final mediaId = '${media['id'] ?? ''}'.trim();
        final postId = '${post['id'] ?? ''}'.trim();
        final id = postId.isNotEmpty && mediaId.isNotEmpty
            ? '${postId}_$mediaId'
            : (mediaId.isNotEmpty ? mediaId : postId);
        if (id.isEmpty) continue;

        final fallback = _siteUrl(
          media['sd_url'] ?? media['url'],
          baseUri: baseUri,
        );
        final tags = <String>[];
        final rawTags = post['tags'];
        if (rawTags is List) {
          for (final rawTag in rawTags.take(24)) {
            final tag = _mapValue(rawTag);
            final value = _stringValue(tag['tag']);
            if (value != null) tags.add(value);
          }
        }

        final thumb = _siteUrl(
          media['thumb_webp_url'] ??
              media['thumb_url'] ??
              media['start_webp_url'] ??
              media['start_url'] ??
              media['blur_webp_url'] ??
              media['blur_url'],
          baseUri: baseUri,
        );
        final avatar = _siteUrl(
          user['public_avatar_url'] ?? user['fans_avatar_url'],
          baseUri: baseUri,
        );

        output.add(
          ReelItem(
            id: id,
            videoUrl: videoUrl,
            fallbackUrl: fallback == videoUrl ? null : fallback,
            downloadUrl: _siteUrl(media['url'] ?? media['fhd_url'], baseUri: baseUri),
            mediaReferer: baseUri.toString(),
            title: _stringValue(post['text']) ??
                _stringValue(post['slug']) ??
                (username.isNotEmpty ? 'Post by $displayName' : 'XXXFollow video'),
            thumbUrl: thumb,
            avatarUrl: avatar,
            author: username,
            views: _intValue(row['view_count']),
            likes: _intValue(row['like_count'] ?? row['favorite_count']),
            durationSec: _intValue(
              media['duration_in_second'] ?? post['video_duration_total'],
            ),
            tags: List<String>.unmodifiable(tags),
          ),
        );
      }
    }
    return output;
  }

  /// Converts creator rows gathered from one or more home-feed pages into
  /// playable Reels. Keeping conversion here makes profile grids use exactly
  /// the same URL validation and media selection as the main Trans feed.
  static List<ReelItem> toReelsFromRows(
    List<Map<String, dynamic>> rows, {
    required Uri baseUri,
  }) {
    return toReels(
      XxxFollowPageData(
        page: 1,
        gender: 't',
        posts: rows,
        nextUri: null,
      ),
      baseUri: baseUri,
    );
  }
}

/// Direct HTML/SSR scraper for XXXFollow's Trans feed. It uses the exact
/// cookie supplied in the user's successful requests.py test and consumes
/// the MP4 URLs already embedded in the returned page. No WKWebView, XFree
/// recommId, or per-video detail-page request is needed for Reels.
class XxxFollowTransReelsRepository {
  XxxFollowTransReelsRepository({http.Client? client, Uri? baseUri})
      : _client = client ?? _createClient(),
        _baseUri = baseUri ?? Uri.parse(_xxxFollowBaseUrl);

  final http.Client _client;
  final Uri _baseUri;
  final Set<String> _seenIds = <String>{};
  final List<ReelItem> _pending = <ReelItem>[];
  final Map<String, XxxFollowCreatorProfile> _profiles =
      <String, XxxFollowCreatorProfile>{};
  final Map<String, List<Map<String, dynamic>>> _authorPosts =
      <String, List<Map<String, dynamic>>>{};

  Uri? _nextPageUri;
  Future<void>? _pageRequest;
  int _loadedPages = 0;
  bool _hasMore = true;
  bool _disposed = false;

  static http.Client _createClient() {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        return CupertinoClient.defaultSessionConfiguration();
      }
    } catch (_) {}
    return http.Client();
  }

  Map<String, String> _headers() => <String, String>{
        'User-Agent': _xxxFollowUserAgent,
        // The successful Python request uses the default */* Accept header.
        'Accept': '*/*',
        'Cookie': 'genders=t',
      };

  Future<void> _loadNextPage() {
    if (_pageRequest != null) return _pageRequest!;
    final task = _loadNextPageInternal();
    _pageRequest = task;
    return task.whenComplete(() => _pageRequest = null);
  }

  Future<void> _loadNextPageInternal() async {
    if (_disposed) throw StateError('XXXFollow repository is closed.');
    if (!_hasMore) return;

    final uri = _nextPageUri ?? _baseUri;
    final response = await _client
        .get(uri, headers: _headers())
        .timeout(const Duration(seconds: 22));
    if (response.statusCode != 200) {
      throw HttpException(
        'XXXFollow returned HTTP ${response.statusCode} for ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}.',
        uri: uri,
      );
    }
    if (response.bodyBytes.length > _maxHtmlBytes) {
      throw const FormatException('XXXFollow HTML response is too large.');
    }

    final source = utf8.decode(response.bodyBytes, allowMalformed: true);
    // Use the final URL after redirects when resolving the next-page link.
    // XXXFollow commonly canonicalizes the bare domain to www.xxxfollow.com.
    final effectiveUri = response.request?.url ?? uri;
    if (effectiveUri.scheme != 'https' ||
        !(effectiveUri.host == _baseUri.host ||
            effectiveUri.host == 'xxxfollow.com' ||
            effectiveUri.host == 'www.xxxfollow.com')) {
      throw const FormatException(
        'XXXFollow redirected the feed request to an unexpected host.',
      );
    }
    final page = XxxFollowTransParser.parsePage(
      source,
      pageUri: effectiveUri,
    );
    if (page.posts.isEmpty) {
      throw FormatException('XXXFollow page ${page.page} contains no feed posts.');
    }

    _loadedPages = page.page > 0 ? page.page : _loadedPages + 1;
    _nextPageUri = page.nextUri;
    _hasMore = page.nextUri != null;

    final items = XxxFollowTransParser.toReels(page, baseUri: _baseUri);
    for (final row in page.posts) {
      final post = _mapValue(row['post']);
      final user = _mapValue(post['user']);
      final profile = XxxFollowCreatorProfile.fromJson(user, baseUri: _baseUri);
      final key = profile.username.toLowerCase();
      if (key.isEmpty) continue;
      _profiles[key] = profile;
      final posts = _authorPosts.putIfAbsent(key, () => <Map<String, dynamic>>[]);
      final postId = '${post['id'] ?? ''}';
      if (postId.isNotEmpty && !posts.any((item) => '${_mapValue(item['post'])['id']}' == postId)) {
        posts.add(row);
      }
    }

    for (final item in items) {
      if (_seenIds.add(item.id)) _pending.add(item);
    }

    if (kDebugMode) {
      debugPrint(
        '[XXXFOLLOW] page=$_loadedPages posts=${page.posts.length} '
        'reels=${items.length} pending=${_pending.length} '
        'hasMore=$_hasMore url=${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
      );
    }
    if (_pending.isEmpty && _hasMore) {
      // The page may contain image-only posts. The nextBatch loop will read
      // another page, but it is bounded so a broken next link cannot spin.
    }
  }

  Future<List<ReelItem>> nextBatch(int amount) async {
    if (amount <= 0) return const <ReelItem>[];
    if (_disposed) throw StateError('XXXFollow repository is closed.');

    final result = <ReelItem>[];
    var pageAttempts = 0;
    while (result.length < amount && pageAttempts < 6) {
      if (_pending.isEmpty) {
        if (!_hasMore) break;
        await _loadNextPage();
        pageAttempts++;
        continue;
      }
      final remaining = amount - result.length;
      final take = remaining < _pending.length ? remaining : _pending.length;
      result.addAll(_pending.take(take));
      _pending.removeRange(0, take);
    }
    if (result.isEmpty && _loadedPages == 0) {
      throw const FormatException(
        'XXXFollow did not provide a Trans feed. Check the response and genders=t cookie.',
      );
    }
    if (result.isEmpty && _pending.isEmpty && _hasMore) {
      throw FormatException(
        'XXXFollow returned no new playable videos after scanning '
        '$_loadedPages pages. The site may have changed its feed markup.',
      );
    }
    return result;
  }

  bool get hasMorePages => !_disposed && _hasMore;

  Future<XxxFollowAccountSnapshot> getAccountSnapshot(String username) async {
    final key = username.trim().toLowerCase();
    if (key.isEmpty) throw const FormatException('Creator username is empty.');
    final profile = _profiles[key];
    if (profile == null) {
      throw FormatException(
        'Creator @$username was not present in the loaded Trans feed yet.',
      );
    }
    return XxxFollowAccountSnapshot(
      profile: profile,
      firstAuthorPosts: List<Map<String, dynamic>>.unmodifiable(
        _authorPosts[key] ?? const <Map<String, dynamic>>[],
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getMoreCreatorPosts(
    XxxFollowAccountSnapshot account, {
    int maxPages = 8,
  }) async {
    if (maxPages < 1) return List<Map<String, dynamic>>.unmodifiable(
      _authorPosts[account.profile.username.toLowerCase()] ??
          const <Map<String, dynamic>>[],
    );
    final key = account.profile.username.toLowerCase();
    for (var index = 0; index < maxPages && _hasMore; index++) {
      await _loadNextPage();
    }
    return List<Map<String, dynamic>>.unmodifiable(
      _authorPosts[key] ?? const <Map<String, dynamic>>[],
    );
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
