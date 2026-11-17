import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'reel_favorites.dart';
import 'reel_seen_store.dart';

const String _xxxFollowBaseUrl = 'https://www.xxxfollow.com/';
const String _xxxFollowUserAgent = kReelUserAgent;
const int _maxHtmlBytes = 12 * 1024 * 1024;
const int _maxSeenIdsInMemory = 1200;

typedef SeenReelLookup = Future<Set<String>> Function(Iterable<String> ids);

String? _stringValue(dynamic value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > 8192) return null;
  return text;
}

int _intValue(dynamic value) => _optionalIntValue(value) ?? 0;

int _firstPositiveCount(Iterable<dynamic> values) {
  for (final value in values) {
    final parsed = _optionalIntValue(value);
    if (parsed != null && parsed > 0) return parsed;
  }
  return 0;
}

int? _optionalIntValue(dynamic value) {
  if (value == null) return null;
  if (value is num && value.isFinite) {
    return value.clamp(0, 2147483647).toInt();
  }
  if (value is Map) {
    // Profile pages sometimes wrap counters as {count: 1234} or
    // {total: "1.2K"}; unwrap those without treating arbitrary maps as 0.
    for (final key in const [
      'count',
      'total',
      'value',
      'formatted',
      'display',
      'number',
    ]) {
      if (!value.containsKey(key)) continue;
      final parsed = _optionalIntValue(value[key]);
      if (parsed != null) return parsed;
    }
    return null;
  }
  if (value is List) return value.length;
  if (value is String) {
    final normalized = value.replaceAll(',', '').trim().toLowerCase();
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)\s*([kmb])?\s*(?:followers?|fans?|following|followings|subscribers?)?$',
    ).firstMatch(normalized);
    if (match != null) {
      final number = double.tryParse(match.group(1)!);
      if (number == null || !number.isFinite) return null;
      final multiplier = switch (match.group(2)) {
        'k' => 1000,
        'm' => 1000000,
        'b' => 1000000000,
        _ => 1,
      };
      final parsed = (number * multiplier).round();
      return parsed.clamp(0, 2147483647).toInt();
    }
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

/// Returns the first URL that is actually usable. A non-null but empty or
/// malformed fhd_url must not prevent falling back to url / sd_url.
String? _firstSiteUrl(
  Iterable<dynamic> candidates, {
  required Uri baseUri,
}) {
  for (final candidate in candidates) {
    final value = _siteUrl(candidate, baseUri: baseUri);
    if (value != null) return value;
  }
  return null;
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
    this.viewsCount,
    this.lastSeenAt,
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
  final int? viewsCount;
  final String? lastSeenAt;

  /// Accepts either a compact `user` object from a feed row or the full
  /// `/api/v1/user/{username}/public?public=1` response.
  factory XxxFollowCreatorProfile.fromJson(
    Map<String, dynamic> json, {
    required Uri baseUri,
  }) {
    final wrapped = _mapValue(json['data']);
    final payload = wrapped.isNotEmpty &&
            (_mapValue(wrapped['user']).isNotEmpty ||
                wrapped.containsKey('post_count') ||
                wrapped.containsKey('content'))
        ? wrapped
        : json;
    final rootUser = _mapValue(payload['user']);
    final user = rootUser.isNotEmpty ? rootUser : payload;
    final content = _mapValue(payload['content']);
    final postCount = _mapValue(
      payload['post_count'] ?? payload['postCount'] ?? user['post_count'],
    );
    final statistics = _mapValue(payload['statistics']);
    final stats = _mapValue(payload['stats']);
    final username = _stringValue(user['username']) ??
        _stringValue(payload['username']) ?? '';

    dynamic firstNonNull(List<dynamic> values) {
      for (final value in values) {
        if (value != null) return value;
      }
      return null;
    }

    final followerRaw = firstNonNull([
      payload['followers_count'],
      payload['followersCount'],
      payload['follower_count'],
      payload['followerCount'],
      payload['fans_count'],
      payload['fan_count'],
      payload['followers'],
      postCount['follows'], // XXXFollow public API's follower total.
      postCount['followers'],
      _mapValue(payload['counts'])['followers'],
      statistics['followers'],
      stats['followers'],
      user['followers_count'],
      user['followers'],
    ]);
    final followingRaw = firstNonNull([
      payload['following_count'],
      payload['followingCount'],
      payload['followings_count'],
      payload['followingsCount'],
      payload['following'],
      payload['followings'],
      user['following_count'],
      user['following'],
      statistics['following'],
      stats['following'],
    ]);

    return XxxFollowCreatorProfile(
      id: '${user['id'] ?? payload['id'] ?? ''}',
      username: username,
      displayName: _stringValue(user['display_name']) ??
          _stringValue(payload['display_name']) ?? username,
      gender: _stringValue(user['gender']) ??
          _stringValue(payload['gender']) ?? '',
      createdAt: _stringValue(user['created_at']) ??
          _stringValue(payload['created_at']) ?? '',
      isStreaming: user['is_streaming'] == true || payload['is_streaming'] == true,
      avatarUrl: _siteUrl(
        user['public_avatar_url'] ??
            user['fans_avatar_url'] ??
            payload['public_avatar_url'],
        baseUri: baseUri,
      ),
      coverPictureUrl: _siteUrl(
        user['public_cover_picture_url'] ?? payload['public_cover_picture_url'],
        baseUri: baseUri,
      ),
      coverVideoUrl: _siteUrl(
        user['public_cover_video_url'] ?? payload['public_cover_video_url'],
        baseUri: baseUri,
      ),
      bio: _stringValue(
        content['public_bio'] ??
            user['bio'] ??
            payload['bio'] ??
            payload['biography'] ??
            payload['about'],
      ),
      followersCount: _optionalIntValue(followerRaw),
      followingCount: _optionalIntValue(followingRaw),
      postsCount: _optionalIntValue(
        firstNonNull([
          payload['posts_count'],
          payload['postsCount'],
          postCount['post'],
          postCount['posts'],
          user['posts_count'],
          user['post_count'],
        ]),
      ),
      likesCount: _optionalIntValue(
        firstNonNull([
          payload['likes_count'],
          payload['post_like_count'],
          payload['like_count'],
          postCount['likes'],
          user['likes_count'],
        ]),
      ),
      viewsCount: _optionalIntValue(
        firstNonNull([
          payload['views_count'],
          payload['view_count'],
          postCount['views'],
          user['views_count'],
        ]),
      ),
      lastSeenAt: _stringValue(user['last_seen_at'] ?? payload['last_seen_at']),
    );
  }
}

class XxxFollowComment {
  const XxxFollowComment({
    required this.id,
    required this.text,
    required this.username,
    required this.displayName,
    required this.likes,
    required this.createdAt,
    this.avatarUrl,
    this.replyCount = 0,
  });

  final String id;
  final String text;
  final String username;
  final String displayName;
  final int likes;
  final String createdAt;
  final String? avatarUrl;
  final int replyCount;
}

class XxxFollowCommentsPage {
  const XxxFollowCommentsPage({
    required this.comments,
    required this.total,
    required this.offset,
    required this.nextOffset,
    required this.hasMore,
  });

  final List<XxxFollowComment> comments;
  final int total;
  final int offset;
  /// Offset after consuming raw API rows, including duplicates or filtered rows.
  final int nextOffset;
  final bool hasMore;
}

class XxxFollowCreatorPostsPage {
  const XxxFollowCreatorPostsPage({
    required this.posts,
    required this.beforeTime,
    required this.hasMore,
  });

  final List<Map<String, dynamic>> posts;
  final String? beforeTime;
  final bool hasMore;
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
    // Match only the exact variable name. In particular, do not confuse it
    // with window.__PRELOADED_STATE__ (which has an extra "ED").
    const marker = 'window.__PRELOAD_STATE__';
    final markerIndex = source.indexOf(marker);
    if (markerIndex < 0) {
      throw const FormatException(
        'XXXFollow did not include window.__PRELOAD_STATE__ in its HTML.',
      );
    }

    // Keep parsing inside the script that owns the assignment so malformed
    // state cannot accidentally consume braces from a later script tag.
    final scriptStart = source.lastIndexOf('<script', markerIndex);
    final scriptEnd = source.indexOf('</script>', markerIndex);
    if (scriptStart < 0 || scriptEnd < 0 || scriptStart >= markerIndex) {
      throw const FormatException('XXXFollow preload script is incomplete.');
    }

    final equalsIndex = source.indexOf('=', markerIndex + marker.length);
    if (equalsIndex < 0 || equalsIndex >= scriptEnd) {
      throw const FormatException('XXXFollow preload state assignment is invalid.');
    }

    var start = equalsIndex + 1;
    while (start < scriptEnd &&
        (source.codeUnitAt(start) == 0x20 ||
            source.codeUnitAt(start) == 0x09 ||
            source.codeUnitAt(start) == 0x0a ||
            source.codeUnitAt(start) == 0x0d)) {
      start++;
    }
    if (start >= scriptEnd || source.codeUnitAt(start) != 0x7b) {
      throw const FormatException('XXXFollow preload state JSON is missing.');
    }

    // Walk balanced JSON object braces while respecting quoted strings and
    // escaped quotes. A regex would stop at braces embedded in post text.
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < scriptEnd; index++) {
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
    String? homeCursorId,
  }) {
    String? rawNext;
    // The feed pagination key is tied to the first post in list-home. Prefer
    // that exact cursor instead of accidentally reading another feed's key.
    if (homeCursorId != null && homeCursorId.isNotEmpty) {
      final pagination = _mapValue(state['pagination-home-$homeCursorId']);
      rawNext = _stringValue(pagination['next']);
    }
    if (rawNext == null) {
      for (final entry in state.entries) {
        if (!entry.key.startsWith('pagination-home-')) continue;
        final pagination = _mapValue(entry.value);
        rawNext = _stringValue(pagination['next']);
        if (rawNext != null) break;
      }
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
    final firstPost = posts.isEmpty ? <String, dynamic>{} : _mapValue(posts.first['post']);
    final homeCursorId = _stringValue('${firstPost['id'] ?? ''}');
    final page = _intValue(home['page']);

    return XxxFollowPageData(
      page: page,
      gender: gender,
      posts: posts,
      nextUri: _readNextUri(
        state,
        source: source,
        pageUri: uri,
        homeCursorId: homeCursorId,
      ),
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
        final mediaType = '${media['type'] ?? ''}'.trim().toLowerCase();
        if (mediaType != 'video') continue;

        // Quality preference: FHD -> original MP4 -> SD -> UHD fallback.
        // Try each candidate independently so an empty/invalid FHD value
        // cannot block a valid original or SD link.
        final videoUrl = _firstSiteUrl(
          <dynamic>[
            media['fhd_url'],
            media['url'],
            media['sd_url'],
            media['uhd_url'],
          ],
          baseUri: baseUri,
        );
        if (videoUrl == null) continue;

        final mediaId = '${media['id'] ?? ''}'.trim();
        final postId = '${post['id'] ?? ''}'.trim();
        final id = postId.isNotEmpty && mediaId.isNotEmpty
            ? '${postId}_$mediaId'
            : (mediaId.isNotEmpty ? mediaId : postId);
        if (id.isEmpty) continue;

        final fallback = _firstSiteUrl(
          <dynamic>[media['sd_url'], media['url'], media['fhd_url']],
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

        final thumb = _firstSiteUrl(
          <dynamic>[
            media['start_webp_url'],
            media['thumb_webp_url'],
            media['thumb_url'],
            media['start_url'],
            media['blur_webp_url'],
            media['blur_url'],
          ],
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
            downloadUrl: _firstSiteUrl(
              <dynamic>[media['url'], media['fhd_url'], media['sd_url']],
              baseUri: baseUri,
            ),
            mediaReferer: baseUri.toString(),
            postId: postId.isNotEmpty ? postId : null,
            title: _stringValue(post['text']) ??
                _stringValue(post['slug']) ??
                (username.isNotEmpty ? 'Post by $displayName' : 'Video'),
            thumbUrl: thumb,
            avatarUrl: avatar,
            author: username,
            views: _firstPositiveCount([
              row['view_count'],
              row['viewCount'],
              row['views'],
              post['view_count'],
              post['viewCount'],
              post['views'],
              _mapValue(post['statistics'])['views'],
              _mapValue(post['stats'])['views'],
              media['view_count'],
            ]),
            commentCount: _firstPositiveCount([
              row['comment_count'],
              row['comments_count'],
              row['commentCount'],
              row['comments'],
              post['comment_count'],
              post['commentCount'],
              post['comments_count'],
              post['commentsCount'],
              post['total_comments'],
              post['comments'],
              _mapValue(post['statistics'])['comments'],
              _mapValue(post['statistics'])['comments_count'],
              _mapValue(post['stats'])['comments'],
              _mapValue(post['stats'])['comment_count'],
            ]),
            likes: _firstPositiveCount([
              row['like_count'],
              row['favorite_count'],
              post['like_count'],
              post['likes_count'],
              post['favorite_count'],
            ]),
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

  /// Parses the public author-post API. Responses have appeared as a raw
  /// array and as objects containing `list`, `posts`, `data`, or `result`.
  /// This normalizes each entry to the `{post: ..., view_count: ...}` shape
  /// consumed by [toReelsFromRows].
  static XxxFollowCreatorPostsPage parseCreatorPostsResponse(
    String source, {
    int limit = 18,
    String? previousBeforeTime,
  }) {
    final decoded = jsonDecode(source);
    final root = _mapValue(decoded);

    List<Map<String, dynamic>> normalize(dynamic candidate) {
      if (candidate is! List) return const <Map<String, dynamic>>[];
      final rows = <Map<String, dynamic>>[];
      for (final raw in candidate) {
        final row = _mapValue(raw);
        if (row.isEmpty) continue;
        final nestedPost = _mapValue(row['post']);
        final directMedia = row['media'];
        final post = nestedPost.isNotEmpty
            ? nestedPost
            : (directMedia is List ? row : _mapValue(row['data']));
        if (post.isEmpty) continue;
        rows.add(nestedPost.isNotEmpty
            ? row
            : <String, dynamic>{
                'post': post,
                if (row['view_count'] != null) 'view_count': row['view_count'],
                if (row['viewCount'] != null) 'viewCount': row['viewCount'],
                if (row['views'] != null) 'views': row['views'],
                if (row['like_count'] != null) 'like_count': row['like_count'],
                if (row['favorite_count'] != null) 'favorite_count': row['favorite_count'],
              });
      }
      return rows;
    }

    List<Map<String, dynamic>>? findRows(dynamic value, [int depth = 0]) {
      if (depth > 6) return null;
      if (value is List) {
        final rows = normalize(value);
        if (rows.isNotEmpty) return rows;
        for (final child in value) {
          final nested = findRows(child, depth + 1);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      } else if (value is Map) {
        final map = _mapValue(value);
        for (final key in const ['list', 'posts', 'items', 'data', 'result', 'public_posts']) {
          if (!map.containsKey(key)) continue;
          final nested = findRows(map[key], depth + 1);
          if (nested != null && nested.isNotEmpty) return nested;
        }
        for (final child in map.values) {
          final nested = findRows(child, depth + 1);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      }
      return null;
    }

    final rows = decoded is List
        ? normalize(decoded)
        : (findRows(root) ?? const <Map<String, dynamic>>[]);

    String? cursorFrom(dynamic value, [int depth = 0]) {
      if (depth > 6) return null;
      if (value is Map) {
        final map = _mapValue(value);
        for (final key in const [
          'next_before_time',
          'nextBeforeTime',
          'before_time',
          'beforeTime',
          'next_cursor',
          'nextCursor',
        ]) {
          final candidate = _stringValue(map[key]);
          if (candidate != null && candidate != previousBeforeTime) {
            return candidate;
          }
        }
        for (final child in map.values) {
          final nested = cursorFrom(child, depth + 1);
          if (nested != null) return nested;
        }
      } else if (value is List) {
        for (final child in value) {
          final nested = cursorFrom(child, depth + 1);
          if (nested != null) return nested;
        }
      }
      return null;
    }

    String? createdAt(Map<String, dynamic> row) {
      final post = _mapValue(row['post']);
      return _stringValue(post['created_at'] ??
          post['createdAt'] ??
          row['created_at'] ??
          row['createdAt']);
    }

    final explicitCursor = cursorFrom(root);
    String? oldest;
    DateTime? oldestDate;
    for (final row in rows) {
      final raw = createdAt(row);
      if (raw == null) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        oldest ??= raw;
      } else if (oldestDate == null || parsed.isBefore(oldestDate)) {
        oldestDate = parsed;
        oldest = raw;
      }
    }
    final cursor = explicitCursor ?? oldest;
    final explicitHasMore = _readHasMore(root);
    final hasMore = explicitHasMore ??
        (rows.length >= limit && cursor != null && cursor != previousBeforeTime);

    return XxxFollowCreatorPostsPage(
      posts: List<Map<String, dynamic>>.unmodifiable(rows),
      beforeTime: cursor,
      hasMore: hasMore && rows.isNotEmpty && cursor != previousBeforeTime,
    );
  }

  static bool? _readHasMore(dynamic value, [int depth = 0]) {
    if (depth > 6) return null;
    if (value is Map) {
      final map = _mapValue(value);
      for (final key in const ['has_more', 'hasMore', 'has_next', 'hasNext']) {
        if (map[key] is bool) return map[key] as bool;
      }
      for (final key in const ['pagination', 'meta', 'page_info', 'pageInfo']) {
        final result = _readHasMore(map[key], depth + 1);
        if (result != null) return result;
      }
    }
    return null;
  }

  /// Converts creator rows gathered from one or more home-feed pages into
  /// playable Reels. Keeping conversion here makes profile grids use exactly
  /// the same URL validation and media selection as the main Trans feed.
  static List<ReelItem> toReelsFromRows(
    List<Map<String, dynamic>> rows, {
    required Uri baseUri,
    XxxFollowCreatorProfile? creator,
  }) {
    final enriched = creator == null
        ? rows
        : rows.map((row) {
            final post = _mapValue(row['post']);
            if (_mapValue(post['user']).isNotEmpty) return row;
            final withUser = <String, dynamic>{
              ...post,
              'user': <String, dynamic>{
                'id': creator.id,
                'username': creator.username,
                'display_name': creator.displayName,
                'gender': creator.gender,
                'created_at': creator.createdAt,
                'is_streaming': creator.isStreaming,
                'public_avatar_url': creator.avatarUrl,
                'public_cover_picture_url': creator.coverPictureUrl,
              },
            };
            return <String, dynamic>{...row, 'post': withUser};
          }).toList(growable: false);
    return toReels(
      XxxFollowPageData(
        page: 1,
        gender: 't',
        posts: enriched,
        nextUri: null,
      ),
      baseUri: baseUri,
    );
  }
}

class _CreatorFeedState {
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  final Set<String> seenPostIds = <String>{};
  String? beforeTime;
  bool hasMore = true;
  Future<List<Map<String, dynamic>>>? request;
}

/// Direct HTML/SSR scraper for XXXFollow's Trans feed. It uses the exact
/// cookie supplied in the user's successful requests.py test and consumes
/// the MP4 URLs already embedded in the returned page. No WKWebView, XFree
/// recommId, or per-video detail-page request is needed for Reels.
class XxxFollowTransReelsRepository {
  XxxFollowTransReelsRepository({
    http.Client? client,
    Uri? baseUri,
    SeenReelLookup? findPreviouslySeenIds,
  })  : _client = client ?? _createClient(),
        _baseUri = baseUri ?? Uri.parse(_xxxFollowBaseUrl),
        _findPreviouslySeenIds = findPreviouslySeenIds;

  final http.Client _client;
  final Uri _baseUri;
  /// IDs seen in this repository session; used only for page de-duplication.
  final Set<String> _seenIds = <String>{};
  final Set<String> _seenVideoUrls = <String>{};
  /// Persisted history is queried for only the IDs in the current page.
  /// The full history is never copied into RAM.
  final SeenReelLookup? _findPreviouslySeenIds;
  final List<ReelItem> _pending = <ReelItem>[];
  final Set<String> _visitedPageUris = <String>{};
  Uri? _nextPageUri;
  Future<void>? _pageRequest;
  int _loadedPages = 0;
  int _consecutiveNoFreshPages = 0;
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
        'Accept': '*/*',
        'Referer': _baseUri.toString(),
        'Origin': _baseUri.origin,
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
    final pageKey = uri.replace(fragment: '').toString();
    if (_visitedPageUris.contains(pageKey)) {
      _hasMore = false;
      _nextPageUri = null;
      return;
    }
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
    _visitedPageUris
      ..add(pageKey)
      ..add(effectiveUri.replace(fragment: '').toString());
    _loadedPages = page.page > 0 ? page.page : _loadedPages + 1;
    final candidateNext = page.nextUri;
    final candidateKey = candidateNext?.replace(fragment: '').toString();
    if (candidateNext == null ||
        candidateKey == pageKey ||
        (candidateKey != null && _visitedPageUris.contains(candidateKey))) {
      _nextPageUri = null;
      _hasMore = false;
    } else {
      _nextPageUri = candidateNext;
      _hasMore = true;
    }

    final items = XxxFollowTransParser.toReels(page, baseUri: _baseUri);
    final previouslySeen = _findPreviouslySeenIds == null || items.isEmpty
        ? const <String>{}
        : await _findPreviouslySeenIds(items.expand((item) => [
              item.id,
              ReelSeenStore.urlKey(item.videoUrl),
            ]).where((key) => key.isNotEmpty));
    var freshAdded = 0;
    for (final item in items) {
      final isNewId = _seenIds.add(item.id);
      final isNewUrl = _seenVideoUrls.add(item.videoUrl);
      if (!isNewId || !isNewUrl) continue;
      // Never recycle an already-viewed reel. Only the compact ID is
      // persisted; media, thumbnails and post data are not retained.
      if (previouslySeen.contains(item.id) ||
          previouslySeen.contains(ReelSeenStore.urlKey(item.videoUrl))) {
        continue;
      }
      _pending.add(item);
      freshAdded++;
    }
    _consecutiveNoFreshPages = freshAdded == 0
        ? _consecutiveNoFreshPages + 1
        : 0;
    // A broken cursor or a long run of already-watched/image-only pages must
    // never leave the UI's trailing Reels page spinning indefinitely.
    if (_consecutiveNoFreshPages >= 8) {
      _hasMore = false;
      _nextPageUri = null;
    }
    // The page cursor advances monotonically, so old in-session dedup keys
    // can be discarded safely once this bounded window is exceeded. The
    // compact disk-backed seen-ID file remains the restart guard.
    while (_seenIds.length > _maxSeenIdsInMemory) {
      _seenIds.remove(_seenIds.first);
    }
    while (_seenVideoUrls.length > _maxSeenIdsInMemory) {
      _seenVideoUrls.remove(_seenVideoUrls.first);
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
    while (result.length < amount && pageAttempts < 8) {
      if (_pending.isEmpty) {
        if (!_hasMore) break;
        await _loadNextPage();
        pageAttempts++;
        if (!_hasMore && _pending.isEmpty) break;
        continue;
      }
      final remaining = amount - result.length;
      final take = remaining < _pending.length ? remaining : _pending.length;
      result.addAll(_pending.take(take));
      _pending.removeRange(0, take);
    }

    // Reaching this scan limit returns an empty batch to the UI, which shows
    // a retry action while preserving the next page cursor. Never recycle
    // watched reels merely to fill the screen.
    if (result.isEmpty && _loadedPages == 0) {
      throw const FormatException(
        'XXXFollow did not provide a Trans feed. Check the genders=t source setting.',
      );
    }
    return result;
  }

  bool get hasMorePages => !_disposed && _hasMore;

  /// True while another feed page exists or reels from the current page
  /// are still waiting in the in-memory queue.
  bool get hasMoreItems => !_disposed && (_hasMore || _pending.isNotEmpty);

  /// Returns the same public Trans feed as lightweight catalogue Video rows.
  /// This lets Home display Trans normally without routing the user to Reels.
  Future<List<Video>> nextHomeBatch(int amount) async {
    final items = await nextBatch(amount);
    return List<Video>.unmodifiable(items.map((item) {
      final duration = item.durationSec;
      final minutes = duration ~/ 60;
      final seconds = duration % 60;
      final creatorUri = item.author.isEmpty
          ? Uri.parse(_xxxFollowBaseUrl)
          : Uri.https('www.xxxfollow.com', '/${item.author}');
      final description = <String>[
        if (item.author.isNotEmpty) '@${item.author}',
        if (item.tags.isNotEmpty) item.tags.map((tag) => '#$tag').join(' '),
      ].join(' · ');
      return Video(
        id: 'xxx_follow_${item.id}',
        title: item.title.isEmpty ? 'Video by ${item.author}' : item.title,
        streamUrl: item.videoUrl,
        description: description,
        thumbnailUrl: item.thumbUrl,
        duration: duration > 0
            ? '$minutes:${seconds.toString().padLeft(2, '0')}'
            : '',
        views: item.views > 0 ? reelCompact(item.views) : '',
        likes: item.likes > 0 ? reelCompact(item.likes) : '',
        category: 'Trans',
        pageUrl: creatorUri.toString(),
        previewUrl: item.thumbUrl ?? '',
      );
    }));
  }

  final Map<String, _CreatorFeedState> _creatorFeeds =
      <String, _CreatorFeedState>{};

  Uri _creatorProfileUri(String username) => Uri(
        scheme: _baseUri.scheme,
        host: _baseUri.host,
        port: _baseUri.hasPort ? _baseUri.port : null,
        pathSegments: ['api', 'v1', 'user', username, 'public'],
        queryParameters: const {'public': '1'},
      );

  Uri _creatorPostsUri(String username, String? beforeTime) {
    final query = <String, String>{
      'limit': '18',
      'sort_by': 'recent',
      if (beforeTime != null && beforeTime.isNotEmpty) 'before_time': beforeTime,
    };
    return Uri(
      scheme: _baseUri.scheme,
      host: _baseUri.host,
      port: _baseUri.hasPort ? _baseUri.port : null,
      pathSegments: ['api', 'v1', 'user', username, 'post', 'public'],
      queryParameters: query,
    );
  }

  Map<String, String> _apiHeaders(String username, {required String accept}) => {
        ..._headers(),
        'Accept': accept,
        'Referer': _baseUri.resolve(Uri.encodeComponent(username)).toString(),
        'Origin': _baseUri.origin,
      };

  Future<XxxFollowCreatorProfile> _fetchCreatorProfile(String username) async {
    final uri = _creatorProfileUri(username);
    final response = await _client
        .get(uri, headers: _apiHeaders(username, accept: 'application/json'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException(
        'Creator profile API returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    if (response.bodyBytes.length > 4 * 1024 * 1024) {
      throw const FormatException('Creator profile response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    final root = _mapValue(decoded);
    if (root.isEmpty) {
      throw const FormatException('Creator profile API returned invalid JSON.');
    }
    final profile = XxxFollowCreatorProfile.fromJson(root, baseUri: _baseUri);
    if (profile.username.isEmpty) {
      throw const FormatException('Creator profile response did not include a username.');
    }
    if (profile.username.toLowerCase() != username.toLowerCase()) {
      throw const FormatException('Creator profile API returned a different account.');
    }
    return profile;
  }

  Future<List<Map<String, dynamic>>> _fetchCreatorPostsPage(
    String username,
    _CreatorFeedState feed,
  ) async {
    if (_disposed) throw StateError('XXXFollow repository is closed.');
    if (!feed.hasMore) return const <Map<String, dynamic>>[];
    final previous = feed.beforeTime;
    final uri = _creatorPostsUri(username, previous);
    final response = await _client
        .get(uri, headers: _apiHeaders(username, accept: 'application/json'))
        .timeout(const Duration(seconds: 24));
    if (response.statusCode != 200) {
      throw HttpException(
        'Creator posts API returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    if (response.bodyBytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Creator posts response is too large.');
    }
    final source = utf8.decode(response.bodyBytes, allowMalformed: true);
    final page = XxxFollowTransParser.parseCreatorPostsResponse(
      source,
      limit: 18,
      previousBeforeTime: previous,
    );
    if (page.posts.isEmpty) {
      feed.hasMore = false;
      return const <Map<String, dynamic>>[];
    }

    var added = 0;
    for (final row in page.posts) {
      final post = _mapValue(row['post']);
      final postId = '${post['id'] ?? ''}'.trim();
      if (postId.isEmpty || !feed.seenPostIds.add(postId)) continue;
      feed.rows.add(row);
      added++;
    }

    final nextCursor = page.beforeTime;
    if (nextCursor == null || nextCursor == previous || added == 0) {
      feed.hasMore = false;
    } else {
      feed.beforeTime = nextCursor;
      feed.hasMore = page.hasMore;
    }
    if (kDebugMode) {
      debugPrint(
        '[XXXFOLLOW] author=$username posts=${page.posts.length} '
        'new=$added hasMore=${feed.hasMore} beforeTime=${feed.beforeTime}',
      );
    }
    return List<Map<String, dynamic>>.unmodifiable(feed.rows);
  }

  Future<List<Map<String, dynamic>>> _ensureCreatorPage(
    String username,
    _CreatorFeedState feed,
  ) {
    final existing = feed.request;
    if (existing != null) return existing;
    final task = _fetchCreatorPostsPage(username, feed);
    feed.request = task;
    return task.whenComplete(() => feed.request = null);
  }

  Future<XxxFollowAccountSnapshot> getAccountSnapshot(String username) async {
    final key = username.trim().toLowerCase();
    if (key.isEmpty) throw const FormatException('Creator username is empty.');

    // This is the site's real public API. Unlike the compact author object in
    // the home feed, it carries public_bio and post_count counters.
    final profile = await _fetchCreatorProfile(key);
    final feed = _creatorFeeds.putIfAbsent(key, _CreatorFeedState.new);
    if (feed.rows.isEmpty && feed.hasMore) {
      await _ensureCreatorPage(key, feed);
    }
    return XxxFollowAccountSnapshot(
      profile: profile,
      firstAuthorPosts: List<Map<String, dynamic>>.unmodifiable(feed.rows),
    );
  }

  bool hasMoreCreatorPosts(String username) {
    final feed = _creatorFeeds[username.toLowerCase()];
    return !_disposed && feed != null && feed.hasMore;
  }

  Future<List<Map<String, dynamic>>> getMoreCreatorPosts(
    XxxFollowAccountSnapshot account, {
    int maxPages = 1,
  }) async {
    final key = account.profile.username.toLowerCase();
    final feed = _creatorFeeds.putIfAbsent(key, _CreatorFeedState.new);
    for (var index = 0; index < maxPages && feed.hasMore; index++) {
      await _ensureCreatorPage(key, feed);
    }
    return List<Map<String, dynamic>>.unmodifiable(feed.rows);
  }

  Future<XxxFollowCommentsPage> getPostComments(
    String postId, {
    int offset = 0,
    int limit = 20,
  }) async {
    if (_disposed) throw StateError('XXXFollow repository is closed.');
    final id = postId.trim();
    if (id.isEmpty || !RegExp(r'^\d+$').hasMatch(id)) {
      throw const FormatException('Invalid XXXFollow post ID.');
    }
    final safeLimit = limit.clamp(1, 50).toInt();
    final safeOffset = offset.clamp(0, 100000).toInt();
    final uri = Uri(
      scheme: _baseUri.scheme,
      host: _baseUri.host,
      pathSegments: ['api', 'v1', 'post', id, 'comment'],
      queryParameters: {'limit': '$safeLimit', 'offset': '$safeOffset'},
    );
    final response = await _client.get(uri, headers: {
      ..._headers(),
      'Accept': 'application/json',
      'Referer': _baseUri.toString(),
      'Origin': _baseUri.origin,
    }).timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) {
      throw HttpException(
        'XXXFollow comments returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    if (response.bodyBytes.length > 3 * 1024 * 1024) {
      throw const FormatException('Comments response is too large.');
    }
    final root = _mapValue(jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    ));
    final rawList = root['list'];
    final rows = rawList is List ? rawList : const <dynamic>[];
    final comments = <XxxFollowComment>[];
    for (final raw in rows) {
      final row = _mapValue(raw);
      final user = _mapValue(row['user']);
      final commentId = '${row['id'] ?? ''}'.trim();
      final text = _stringValue(row['comment']) ?? '';
      if (commentId.isEmpty || text.isEmpty) continue;
      comments.add(XxxFollowComment(
        id: commentId,
        text: text,
        username: _stringValue(user['username']) ?? '',
        displayName: _stringValue(user['display_name']) ??
            _stringValue(user['username']) ?? 'User',
        likes: _intValue(row['likes'] ?? row['compound_likes']),
        createdAt: _stringValue(row['created_at']) ?? '',
        avatarUrl: _siteUrl(
          user['public_avatar_url'] ?? user['fans_avatar_url'],
          baseUri: _baseUri,
        ),
        replyCount: _intValue(_mapValue(row['replies'])['count']),
      ));
    }
    // count_total is the authoritative total. `count` can represent either
    // the page size or the total on older API variants, so use it only for the
    // display count and fall back to page-size inference when total is absent.
    final totalFromApi = _optionalIntValue(root['count_total']);
    final total = totalFromApi ?? _intValue(root['count']);
    final nextOffset = safeOffset + rows.length;
    final explicitHasMore = root['has_more'] is bool
        ? root['has_more'] as bool
        : (root['hasMore'] is bool ? root['hasMore'] as bool : null);
    final hasKnownTotal = totalFromApi != null && totalFromApi > 0;
    final hasMore = rows.isNotEmpty &&
        nextOffset > safeOffset &&
        (hasKnownTotal
            ? nextOffset < totalFromApi
            : (explicitHasMore ?? rows.length >= safeLimit));
    return XxxFollowCommentsPage(
      comments: List<XxxFollowComment>.unmodifiable(comments),
      total: total,
      offset: safeOffset,
      nextOffset: nextOffset,
      hasMore: hasMore,
    );
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
