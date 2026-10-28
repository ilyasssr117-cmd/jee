import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'video_card.dart';

class SliverVideoGrid extends StatelessWidget {
  const SliverVideoGrid({
    super.key,
    required this.videos,
    required this.onOpen,
    this.padding = EdgeInsets.zero,
  });

  final List<Video> videos;
  final ValueChanged<Video> onOpen;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = videoGridColumns(context);
        const gap = Gaps.md;
        final width = constraints.crossAxisExtent - padding.horizontal;
        final cardWidth = ((width - gap * (columns - 1)) / columns)
            .clamp(0.0, double.infinity)
            .toDouble();

        return SliverPadding(
          padding: padding,
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: Gaps.lg,
              mainAxisExtent: VideoCardMetrics.height(context, cardWidth),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final video = videos[index];
                return VideoCard(
                  key: ValueKey<String>(video.id),
                  video: video,
                  onTap: () => onOpen(video),
                );
              },
              childCount: videos.length,
            ),
          ),
        );
      },
    );
  }
}
