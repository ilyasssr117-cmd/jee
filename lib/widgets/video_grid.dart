import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorites_store.dart';
import '../models.dart';
import 'tv_controls.dart';
import 'video_card.dart';

class SliverVideoGrid extends StatelessWidget {
  const SliverVideoGrid({
    super.key,
    required this.videos,
    required this.onOpen,
    this.padding = EdgeInsets.zero,
    this.tvMode = false,
  });

  final List<Video> videos;
  final ValueChanged<Video> onOpen;
  final EdgeInsets padding;

  /// Television: render the dedicated remote-focusable [TvVideoCard]
  /// (fix TV-2 — it existed but was never wired into any surface).
  final bool tvMode;

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
              mainAxisExtent: tvMode
                  ? cardWidth * 9 / 16 + 86
                  : VideoCardMetrics.height(context, cardWidth),
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final video = videos[index];
              if (tvMode) {
                return TvVideoCard(
                  key: ValueKey<String>(video.id),
                  video: video,
                  width: cardWidth,
                  onPressed: () => onOpen(video),
                  onBookmark: () =>
                      FavoritesStore.instance.toggle(video),
                );
              }
              return VideoCard(
                key: ValueKey<String>(video.id),
                video: video,
                onTap: () => onOpen(video),
              );
            }, childCount: videos.length),
          ),
        );
      },
    );
  }
}
