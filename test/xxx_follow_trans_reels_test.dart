import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:vxtube_final/xxx_follow_trans_reels.dart';

const String _pageHtml = r'''
<!doctype html>
<html>
<head>
  <link rel="next" href="https://www.xxxfollow.com/?page=2" />
</head>
<body>
<script>
window.__PRELOAD_STATE__ = {
  "list-home": {
    "genders": "t",
    "page": 1,
    "list": [
      {
        "like_count": 24,
        "favorite_count": 4,
        "view_count": 1200,
        "post": {
          "id": 1001,
          "text": "Sample Trans post",
          "video_duration_total": 12,
          "media": [
            {
              "type": "video",
              "id": 2001,
              "url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001.mp4",
              "fhd_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_fhd.mp4",
              "sd_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_sd.mp4",
              "thumb_webp_url": "https://www.xxxfollow.com/media/fans/post_public/1/2/2001_small.webp",
              "duration_in_second": 12
            }
          ],
          "user": {
            "id": 22,
            "username": "sample_creator",
            "display_name": "Sample Creator",
            "gender": "t",
            "created_at": "2026-01-01T00:00:00+0000",
            "public_avatar_url": "https://www.xxxfollow.com/media/fans/avatar/1/2/avatar.jpg",
            "public_cover_picture_url": null,
            "is_streaming": false
          },
          "tags": [{"id": 1, "tag": "trans"}, {"id": 2, "tag": "sample"}]
        }
      }
    ]
  },
  "pagination-home-1001": {
    "next": "https://www.xxxfollow.com/?page=2",
    "prev": null
  }
};
</script>
</body>
</html>
''';

const String _creatorProfileHtml = r'''
<!doctype html>
<html><body><script>
window.__PRELOAD_STATE__ = {
  "creator-profile": {
    "profile": {
      "id": 22,
      "username": "sample_creator",
      "display_name": "Sample Creator",
      "gender": "t",
      "created_at": "2026-01-01T00:00:00+0000",
      "followers_count": 12500,
      "following_count": 84,
      "posts_count": 37,
      "likes_count": 91000,
      "bio": "Creator biography",
      "statistics": {"followers": 12500, "following": 84}
    }
  }
};
</script></body></html>
''';

void main() {
  group('XXXFollow Trans feed parser', () {
    test('reads posts, direct MP4, creator metadata and pagination', () {
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
      expect(items.single.views, 1200);
      expect(items.single.durationSec, 12);
      expect(items.single.tags, ['trans', 'sample']);
    });

    test('requires the Trans gender cookie state', () {
      final html = _pageHtml.replaceFirst('"genders": "t"', '"genders": "f"');
      expect(
        () => XxxFollowTransParser.parsePage(html),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('repository sends genders=t and returns the first reel batch', () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      final body = request.url.path == '/sample_creator'
          ? _creatorProfileHtml
          : _pageHtml;
      return http.Response(
        body,
        200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final repository = XxxFollowTransReelsRepository(client: client);
    addTearDown(repository.dispose);

    final items = await repository.nextBatch(1);
    expect(items, hasLength(1));
    expect(captured?.headers['cookie'], 'genders=t');
    expect(captured?.url.host, 'www.xxxfollow.com');

    final account = await repository.getAccountSnapshot('sample_creator');
    expect(account.profile.displayName, 'Sample Creator');
    expect(account.profile.followersCount, 12500);
    expect(account.profile.followingCount, 84);
    expect(account.profile.postsCount, 37);
    expect(account.firstAuthorPosts, hasLength(1));
  });

  test('profile parser preserves optional social counters when supplied', () {
    final profile = XxxFollowCreatorProfile.fromJson(
      <String, dynamic>{
        'id': 22,
        'username': 'sample_creator',
        'display_name': 'Sample Creator',
        'gender': 't',
        'created_at': '2026-01-01T00:00:00+0000',
        'is_streaming': true,
        'followers_count': 12500,
        'following_count': 84,
        'posts_count': 37,
        'likes_count': 91000,
        'bio': 'Creator biography',
      },
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(profile.followersCount, 12500);
    expect(profile.followingCount, 84);
    expect(profile.postsCount, 37);
    expect(profile.likesCount, 91000);
    expect(profile.bio, 'Creator biography');
  });

  test('profile parser unwraps nested and formatted follower counters', () {
    final profile = XxxFollowCreatorProfile.fromJson(
      <String, dynamic>{
        'id': 22,
        'username': 'sample_creator',
        'display_name': 'Sample Creator',
        'statistics': {
          'followers': {'count': '12.5K'},
          'following': {'total': '84'},
        },
      },
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(profile.followersCount, 12500);
    expect(profile.followingCount, 84);
  });

  test('creator rows can be converted into playable profile-grid reels', () {
    final page = XxxFollowTransParser.parsePage(_pageHtml);
    final reels = XxxFollowTransParser.toReelsFromRows(
      page.posts,
      baseUri: Uri.parse('https://www.xxxfollow.com/'),
    );
    expect(reels, hasLength(1));
    expect(reels.single.author, 'sample_creator');
    expect(reels.single.videoUrl, contains('.mp4'));
  });

}
