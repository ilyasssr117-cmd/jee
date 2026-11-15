import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/xfree_trans_reels.dart';
import 'package:vxtube_final/reel_favorites.dart';

void main() {
  test('XFree profile parser maps known account fields and avatar URL', () {
    final profile = XFreeAccountProfile.fromJson(<String, dynamic>{
      'id': 1441918,
      'uid': '0198971c-898e-7e7d-9911-fee82ec4b22b',
      'username': 'deusasdoonylfans',
      'displayName': 'DeusasdoOnylfans',
      'bio': 'Perfil pronto para realizar seus desejos',
      'hitCount': 355685,
      'postLikeCount': 196556,
      'postViewCount': 4756133,
      'postsUnlisted': 5,
      'postsPublished': 83,
      'following': 51,
      'followers': 8267,
      'postsCount': 1092,
      'lastActive': '2026-11-14T10:30:00Z',
      'lastPostDate': '2026-11-13T08:15:00Z',
      'avatarMedia': <String, dynamic>{
        'name': 'ae818980-875c-4bb8-a143-e9481f037462',
      },
    });

    expect(profile.id, '1441918');
    expect(profile.username, 'deusasdoonylfans');
    expect(profile.displayName, 'DeusasdoOnylfans');
    expect(profile.followers, 8267);
    expect(profile.following, 51);
    expect(profile.postsCount, 1092);
    expect(profile.postsPublished, 83);
    expect(profile.postsUnlisted, 5);
    expect(profile.lastActive, '2026-11-14T10:30:00Z');
    expect(profile.lastPostDate, '2026-11-13T08:15:00Z');
    expect(profile.postViewCount, 4756133);
    expect(
      profile.avatarUrl,
      'https://thumbs.xfree.com/avatar/medium/'
      'ae818980-875c-4bb8-a143-e9481f037462.png',
    );
  });
  test('ReelItem keeps the XFree media referer when serialized', () {
    const item = ReelItem(
      id: 'post-1',
      videoUrl: 'https://cdn.xfree.com/video/full.mp4',
      mediaReferer: 'https://www.xfree.com/',
    );

    final restored = ReelItem.fromJson(item.toJson());
    expect(restored, isNotNull);
    expect(restored!.mediaReferer, 'https://www.xfree.com/');
  });

}
