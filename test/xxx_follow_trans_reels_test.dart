import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:vxtube_final/xxx_follow_trans_reels.dart';

const String _pageHtml = r'''
<!doctype html>
<html><head><link rel="next" href="https://www.xxxfollow.com/?page=2" /></head>
<body><script>
window.__PRELOAD_STATE__ = {
  "list-home": {
    "genders": "t", "page": 1,
    "list": [{
      "like_count": 24, "favorite_count": 4, "view_count": 1200, "comment_count": 308,
      "post": {
        "id": 1001, "text": "Sample Trans post", "video_duration_total": 12,
        "media": [{
          "type": "video", "id": 2001,
          "url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001.mp4",
          "fhd_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_fhd.mp4",
          "sd_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_sd.mp4",
          "thumb_webp_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_small.webp",
          "duration_in_second": 12
        }],
        "user": {
          "id": 22, "username": "sample_creator", "display_name": "Sample Creator",
          "gender": "t", "created_at": "2026-01-01T00:00:00+0000",
          "public_avatar_url": "https://www.xxxfollow.com/media/fans/avatar/1/2/avatar.jpg",
          "public_cover_picture_url": null, "is_streaming": false
        },
        "tags": [{"id": 1, "tag": "trans"}, {"id": 2, "tag": "sample"}]
      }
    }]
  },
  "pagination-home-1001": {"next": "https://www.xxxfollow.com/?page=2", "prev": null}
};
</script></body></html>
''';

const String _creatorProfileJson = r'''
{"content":{"public_bio":"Creator biography"},
 "post_count":{"follows":12500,"likes":91000,"views":1936599,"post":37},
 "user":{"id":22,"username":"sample_creator","display_name":"Sample Creator",
         "gender":"t","created_at":"2026-01-01T00:00:00+0000",
         "public_avatar_url":"https://www.xxxfollow.com/media/fans/avatar/1/2/avatar.jpg",
         "public_cover_picture_url":null,"public_cover_video_url":null,
         "is_streaming":false,"last_seen_at":"2026-11-15T20:47:32+0000"}}
''';

const String _creatorPostsJson = r'''
{"list":[
 {"view_count":4321,"like_count":77,"post":{"id":3001,
  "created_at":"2026-10-23T15:57:46+0000","text":"Creator video",
  "media":[{"type":"video","id":4001,
   "url":"https://www.xxxfollow.com/media/fans/post_public/1/2/4001.mp4",
   "sd_url":"https://www.xxxfollow.com/media/fans/post_public/1/2/4001_sd.mp4",
   "thumb_webp_url":"https://www.xxxfollow.com/media/fans/post_public/1/2/4001_small.webp",
   "duration_in_second":19}]}}
 ],"has_more":true}
''';

void main() {
  group('XXXFollow Trans feed parser', () {
    test('reads SSR posts, direct MP4, metadata, views and pagination', () {
      final page = XxxFollowTransParser.parsePage(_pageHtml);
      expect(page.page, 1);
      expect(page.gender, 't');
      expect(page.posts, hasLength(1));
      expect(page.nextUri?.queryParameters['page'], '2');

      final items = XxxFollowTransParser.toReels(
        page,
        baseUri: Uri.parse('https://www.xxxfollow.com/'),
      );
      expect(items, hasLength(1));
      expect(items.single.id, '1001_2001');
      expect(items.single.videoUrl, endsWith('2001_fhd.mp4'));
      expect(items.single.thumbUrl, endsWith('2001_small.webp'));
      expect(items.single.author, 'sample_creator');
      expect(items.single.likes, 24);
      expect(items.single.commentCount, 308);
      expect(items.single.views, 1200);
      expect(items.single.durationSec, 12);
      expect(items.single.mediaReferer, 'https://www.xxxfollow.com/');
      expect(items.single.tags, ['trans', 'sample']);
    });

    test('ignores PRELOADED_STATE decoy and falls back from empty FHD URL', () {
      final html = _pageHtml
          .replaceFirst(
            'window.__PRELOAD_STATE__ =',
            'window.__PRELOADED_STATE__ = {\"wrong\":true};\nwindow.__PRELOAD_STATE__ =',
          )
          .replaceFirst(
            '"fhd_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_fhd.mp4"',
            '"fhd_url": ""',
          );
      final page = XxxFollowTransParser.parsePage(html);
      final reels = XxxFollowTransParser.toReels(
        page,
        baseUri: Uri.parse('https://www.xxxfollow.com/'),
      );
      expect(reels, hasLength(1));
      expect(reels.single.videoUrl, endsWith('/2001.mp4'));
    });

    test('requires the Trans gender cookie state', () {
      final html = _pageHtml.replaceFirst('"genders": "t"', '"genders": "f"');
      expect(
        () => XxxFollowTransParser.parsePage(html),
        throwsA(isA<FormatException>()),
      );
    });

    test('normalizes the creator post API and reads before_time cursor', () {
      final page = XxxFollowTransParser.parseCreatorPostsResponse(
        _creatorPostsJson,
      );
      expect(page.posts, hasLength(1));
      expect(page.beforeTime, '2026-10-23T15:57:46+0000');
      expect(page.hasMore, isTrue);
      final reels = XxxFollowTransParser.toReelsFromRows(
        page.posts,
        baseUri: Uri.parse('https://www.xxxfollow.com/'),
      );
      expect(reels, hasLength(1));
      expect(reels.single.views, 4321);
      expect(reels.single.likes, 77);
    });
  });

  test('repository uses the public profile and author-post APIs', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/') return http.Response(_pageHtml, 200);
      if (request.url.path == '/api/v1/user/sample_creator/public') {
        return http.Response(_creatorProfileJson, 200);
      }
      if (request.url.path == '/api/v1/user/sample_creator/post/public') {
        return http.Response(_creatorPostsJson, 200);
      }
      return http.Response('not found', 404);
    });
    final repository = XxxFollowTransReelsRepository(client: client);
    addTearDown(repository.dispose);

    final items = await repository.nextBatch(1);
    expect(items, hasLength(1));
    expect(items.single.views, 1200);
    expect(requests.first.headers['cookie'], 'genders=t');
    expect(requests.first.url.host, 'www.xxxfollow.com');

    final account = await repository.getAccountSnapshot('sample_creator');
    expect(account.profile.displayName, 'Sample Creator');
    expect(account.profile.bio, 'Creator biography');
    expect(account.profile.followersCount, 12500);
    expect(account.profile.followingCount, isNull);
    expect(account.profile.postsCount, 37);
    expect(account.profile.likesCount, 91000);
    expect(account.profile.viewsCount, 1936599);
    expect(account.firstAuthorPosts, hasLength(1));

    final authorReels = XxxFollowTransParser.toReelsFromRows(
      account.firstAuthorPosts,
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
      creator: account.profile,
    );
    expect(authorReels, hasLength(1));
    expect(authorReels.single.author, 'sample_creator');
    expect(authorReels.single.views, 4321);
    expect(repository.hasMoreCreatorPosts('sample_creator'), isTrue);
  });

  test('creator posts pagination sends before_time from the previous page', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v1/user/sample_creator/public') {
        return http.Response(_creatorProfileJson, 200);
      }
      if (request.url.path == '/api/v1/user/sample_creator/post/public') {
        if (!request.url.queryParameters.containsKey('before_time')) {
          return http.Response(_creatorPostsJson, 200);
        }
        return http.Response(
          r'{"list":[{"view_count":18,"post":{"id":3002,"created_at":"2026-10-20T10:00:00+0000","media":[{"type":"video","id":4002,"url":"https://www.xxxfollow.com/media/fans/post_public/1/2/4002.mp4","thumb_webp_url":"https://www.xxxfollow.com/media/fans/post_public/1/2/4002_small.webp"}]}}],"has_more":false}',
          200,
        );
      }
      return http.Response(_pageHtml, 200);
    });
    final repository = XxxFollowTransReelsRepository(client: client);
    addTearDown(repository.dispose);
    final account = await repository.getAccountSnapshot('sample_creator');
    final rows = await repository.getMoreCreatorPosts(account, maxPages: 1);
    expect(rows, hasLength(2));

    final authorRequests = requests.where(
      (request) => request.url.path == '/api/v1/user/sample_creator/post/public',
    ).toList();
    expect(authorRequests, hasLength(2));
    expect(
      authorRequests.last.url.queryParameters['before_time'],
      '2026-10-23T15:57:46+0000',
    );
    expect(repository.hasMoreCreatorPosts('sample_creator'), isFalse);
  });

  test('profile parser unwraps nested and formatted counters', () {
    final profile = XxxFollowCreatorProfile.fromJson(
      <String, dynamic>{
        'user': {'id': 22, 'username': 'sample_creator', 'display_name': 'Sample'},
        'content': {'public_bio': 'nested bio'},
        'post_count': {
          'follows': '12.5K',
          'likes': 91000,
          'views': 1936599,
          'post': 37,
        },
      },
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(profile.followersCount, 12500);
    expect(profile.followingCount, isNull);
    expect(profile.postsCount, 37);
    expect(profile.likesCount, 91000);
    expect(profile.viewsCount, 1936599);
    expect(profile.bio, 'nested bio');
  });

  test('view counter falls through zero and parses compact values', () {
    final page = XxxFollowTransParser.parseCreatorPostsResponse(
      r'''{"list":[{"view_count":0,"post":{"id":77,"stats":{"views":"1.2K"},"media":[{"type":"video","id":78,"url":"https://www.xxxfollow.com/media/77.mp4"}]}}],"has_more":false}''',
    );
    final reels = XxxFollowTransParser.toReelsFromRows(
      page.posts,
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(reels, hasLength(1));
    expect(reels.single.views, 1200);
    expect(reels.single.postId, '77');
  });

  test('profile parser accepts a data envelope but does not invent following', () {
    final profile = XxxFollowCreatorProfile.fromJson(
      <String, dynamic>{
        'data': {
          'content': {'public_bio': 'wrapped bio'},
          'post_count': {'follows': 7898, 'views': 1000, 'post': 156},
          'user': {'id': 45460523, 'username': 'lettiebrown', 'display_name': 'LettieBrown'},
        },
      },
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(profile.followersCount, 7898);
    expect(profile.followingCount, isNull);
    expect(profile.postsCount, 156);
    expect(profile.bio, 'wrapped bio');
  });
  test('Home can load the Trans feed as normal Video catalog items', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'www.xxxfollow.com');
      expect(request.headers['cookie'], 'genders=t');
      expect(request.headers['referer'], 'https://www.xxxfollow.com/');
      expect(request.headers['origin'], 'https://www.xxxfollow.com');
      return http.Response(_pageHtml, 200);
    });
    final repository = XxxFollowTransReelsRepository(client: client);
    addTearDown(repository.dispose);

    final videos = await repository.nextHomeBatch(1);
    expect(videos, hasLength(1));
    expect(videos.single.id, 'xxx_follow_1001_2001');
    expect(videos.single.streamUrl, endsWith('2001_fhd.mp4'));
    expect(videos.single.thumbnailUrl, endsWith('2001_small.webp'));
    expect(videos.single.views, '1.2K');
    expect(videos.single.likes, '24');
    expect(videos.single.category, 'Trans');
    expect(videos.single.pageUrl, 'https://www.xxxfollow.com/sample_creator');
  });

  test('Reels repository can skip previously seen Trans IDs after restart', () async {
    final pageTwo = _pageHtml
        .replaceAll('1001', '1002')
        .replaceAll('2001', '2002')
        .replaceAll('"page": 1', '"page": 2')
        .replaceAll('?page=2', '?page=3');
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(calls == 1 ? _pageHtml : pageTwo, 200);
    });
    final repository = XxxFollowTransReelsRepository(
      client: client,
      findPreviouslySeenIds: (ids) async =>
          ids.where((id) => id == '1001_2001').toSet(),
    );
    addTearDown(repository.dispose);

    final reels = await repository.nextBatch(1);
    expect(reels, hasLength(1));
    expect(reels.single.id, '1002_2002');
    expect(calls, 2);
  });


  test('stops scanning when multiple pages contain only seen reels', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final pageNumber = int.tryParse(
            request.url.queryParameters['page'] ?? '1',
          ) ??
          1;
      final postId = 1000 + pageNumber;
      final mediaId = 2000 + pageNumber;
      final html = _pageHtml
          .replaceAll('1001', '$postId')
          .replaceAll('2001', '$mediaId')
          .replaceAll('"page": 1', '"page": $pageNumber')
          .replaceAll('?page=2', '?page=${pageNumber + 1}');
      return http.Response(html, 200);
    });
    final repository = XxxFollowTransReelsRepository(
      client: client,
      findPreviouslySeenIds: (ids) async => ids.toSet(),
    );
    addTearDown(repository.dispose);

    final reels = await repository.nextBatch(1);
    expect(reels, isEmpty);
    expect(calls, 8);
    expect(repository.hasMoreItems, isFalse);
  });

  test('Reels never recycle a previously watched video when the feed ends', () async {
    final onePage = _pageHtml
        .replaceFirst(
          '<link rel="next" href="https://www.xxxfollow.com/?page=2" />',
          '',
        )
        .replaceFirst(
          '"next": "https://www.xxxfollow.com/?page=2"',
          '"next": null',
        );
    final client = MockClient((request) async => http.Response(onePage, 200));
    final repository = XxxFollowTransReelsRepository(
      client: client,
      findPreviouslySeenIds: (ids) async => ids.toSet(),
    );
    addTearDown(repository.dispose);

    final reels = await repository.nextBatch(1);
    expect(reels, isEmpty);
    expect(repository.hasMoreItems, isFalse);
  });


  test('Trans Reels comments use the public post comments endpoint', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/post/1108943/comment');
      expect(request.url.queryParameters['limit'], '20');
      expect(request.url.queryParameters['offset'], '0');
      expect(request.headers['cookie'], 'genders=t');
      return http.Response(
        r'''{"count":1,"count_total":1,"list":[{"id":464956,"post_id":1108943,"comment":"sample comment","created_at":"2026-03-16T00:56:45+0000","likes":2,"replies":{"count":0,"list":[]},"user":{"display_name":"Sample User","username":"sampleuser","gender":"m"}}]}''',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repository = XxxFollowTransReelsRepository(
      client: client,
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    addTearDown(repository.dispose);

    final page = await repository.getPostComments('1108943');
    expect(page.total, 1);
    expect(page.comments, hasLength(1));
    expect(page.comments.single.id, '464956');
    expect(page.comments.single.text, 'sample comment');
    expect(page.comments.single.displayName, 'Sample User');
    expect(page.nextOffset, 1);
    expect(page.hasMore, isFalse);
  });


  test('comments pagination consumes raw rows and detects the final page', () async {
    final offsets = <String?>[];
    final client = MockClient((request) async {
      offsets.add(request.url.queryParameters['offset']);
      if (request.url.queryParameters['offset'] == '0') {
        return http.Response(
          r'''{"count_total":3,"list":[{"id":1,"comment":"one","user":{}},{"id":2,"comment":"two","user":{}}]}''',
          200,
        );
      }
      return http.Response(
        r'''{"count_total":3,"list":[{"id":3,"comment":"three","user":{}}]}''',
        200,
      );
    });
    final repository = XxxFollowTransReelsRepository(
      client: client,
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    addTearDown(repository.dispose);

    final first = await repository.getPostComments('1108943', limit: 2);
    expect(first.comments, hasLength(2));
    expect(first.nextOffset, 2);
    expect(first.hasMore, isTrue);

    final last = await repository.getPostComments(
      '1108943',
      offset: first.nextOffset,
      limit: 2,
    );
    expect(last.comments, hasLength(1));
    expect(last.nextOffset, 3);
    expect(last.hasMore, isFalse);
    expect(offsets, ['0', '2']);
  });

}
