import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/reels_page.dart';

void main() {
  test('parseReels reads likes from flat and nested API fields', () {
    final items = parseReels(<String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{
          'video_id': 'reel-a',
          'mp4_url': 'https://cdn.example.test/a.mp4',
          'like_count': '143.2K',
        },
        <String, dynamic>{
          'video_id': 'reel-b',
          'mp4_url': 'https://cdn.example.test/b.mp4',
          'statistics': <String, dynamic>{'likes_count': 2345},
        },
        <String, dynamic>{
          'video_id': 'reel-c',
          'mp4_url': 'https://cdn.example.test/c.mp4',
          'likeCount': 0,
        },
      ],
    });

    expect(items, hasLength(3));
    expect(items[0].likes, 143200);
    expect(items[1].likes, 2345);
    expect(items[2].likes, 0);
  });
}
