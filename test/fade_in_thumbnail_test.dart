import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/widgets/fade_in_thumbnail.dart';

class _PendingImageProvider extends ImageProvider<_PendingImageProvider> {
  @override
  Future<_PendingImageProvider> obtainKey(ImageConfiguration configuration) =>
      Future<_PendingImageProvider>.value(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

void main() {
  testWidgets('new thumbnails fade once and revisited identities show directly', (
    tester,
  ) async {
    const identity = 'https://cdn.example.test/unique-fade-test.jpg';
    const key = ValueKey<String>(identity);
    BuildContext? imageContext;
    final image = _PendingImageProvider();

    Widget buildThumbnail() => MaterialApp(
      home: Builder(
        builder: (context) {
          imageContext = context;
          return Center(
            child: SizedBox(
              width: 80,
              height: 60,
              child: FadeInThumbnail(
                key: const ValueKey<String>('fade-widget'),
                identity: identity,
                image: image,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: Colors.red,
                ),
              ),
            ),
          );
        },
      ),
    );

    await tester.pumpWidget(buildThumbnail());
    final frameBuilder = tester.widget<Image>(find.byKey(key)).frameBuilder!;
    const child = SizedBox(width: 80, height: 60);
    final waiting = frameBuilder(imageContext!, child, null, false);
    expect(waiting, isA<AnimatedOpacity>());
    expect((waiting as AnimatedOpacity).opacity, 0);

    final firstFrame = frameBuilder(imageContext!, child, 0, false);
    expect(firstFrame, isA<AnimatedOpacity>());
    expect((firstFrame as AnimatedOpacity).opacity, 1);
    expect(firstFrame.duration, const Duration(milliseconds: 190));
    await tester.pump(const Duration(milliseconds: 190));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(buildThumbnail());
    final remountedBuilder = tester.widget<Image>(find.byKey(key)).frameBuilder!;
    final cachedFrame = remountedBuilder(imageContext!, child, null, false);
    expect(identical(cachedFrame, child), isTrue);
  });
}
