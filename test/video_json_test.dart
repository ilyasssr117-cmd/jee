import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/video_json.dart';

void main() {
  test('persisted video metadata never includes expiring stream URLs', () {
    const video = Video(
      id: 'video-1',
      title: 'Example',
      streamUrl: 'https://cdn.example.test/video.mp4?token=secret',
      thumbnailUrl: 'https://cdn.example.test/thumb.jpg',
      pageUrl: 'https://catalog.example.test/video/1/',
      qualities: <StreamQuality>[
        StreamQuality(height: 1080, url: 'https://cdn.example.test/1080.mp4'),
      ],
    );

    final encoded = videoToJson(video);
    expect(encoded.containsKey('streamUrl'), isFalse);
    expect(encoded.containsKey('qualities'), isFalse);

    final restored = videoFromJson(encoded)!;
    expect(restored.streamUrl, isEmpty);
    expect(restored.qualities, isEmpty);
    expect(restored.title, 'Example');
  });

  test('persisted text fields are bounded', () {
    final encoded = videoToJson(
      Video(id: 'x', title: 't' * 1000, description: 'd' * 5000),
    );
    expect((encoded['title'] as String).length, 300);
    expect((encoded['description'] as String).length, 1500);
  });
  test('persisted artwork and page links must be safe HTTP URLs', () {
    final restored = videoFromJson(<String, dynamic>{
      'id': 'video-2',
      'title': 'Example',
      'thumb': 'javascript:alert(1)',
      'page': 'file:///etc/passwd',
    })!;
    expect(restored.thumbnailUrl, isNull);
    expect(restored.pageUrl, isNull);
  });
}
