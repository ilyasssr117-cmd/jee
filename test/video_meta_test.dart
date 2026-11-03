import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/models.dart';
import 'package:vxtube_final/widgets/video_meta.dart';

void main() {
  group('compactMetric', () {
    test('formats counts without exposing clipped source strings', () {
      expect(compactMetric('4,200 views'), '4.2K');
      expect(compactMetric('12,000 likes'), '12K');
      expect(compactMetric('1,400,000 views'), '1.4M');
    });

    test('normalizes abbreviated and locale formatted values', () {
      expect(compactMetric('4.2k views'), '4.2K');
      expect(compactMetric('1,4k views'), '1.4K');
      expect(compactMetric('1.234.567'), '1.2M');
    });

    test('promotes values that round into the next unit', () {
      expect(compactMetric('999,999'), '1M');
      expect(compactMetric('999,999,999'), '1B');
      expect(compactMetric('980'), '980');
    });

    testWidgets('compact metrics fit on a narrow video card', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 170,
              child: VideoMetaLine(
                video: Video(
                  id: 'video',
                  title: 'Video',
                  likes: '12,000 likes',
                  views: '4,200 views',
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('12K'), findsOneWidget);
      expect(find.text('4.2K'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
