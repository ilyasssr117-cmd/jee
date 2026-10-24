import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'video_card.dart';

/// Number of columns used for video grids on every TV size. Sizes derive from
/// the available width, so the grid keeps the same look at 720p, 1080p and 4K.
const int kVideoGridColumns = 4;

/// Sliver grid of [VideoCard]s with row height computed from the card width.
class SliverVideoGrid extends StatelessWidget {
  const SliverVideoGrid({
    super.key,
    required this.videos,
    required this.onOpen,
    this.onItemFocus,
    this.firstItemFocusNode,
    this.padding = EdgeInsets.zero,
  });

  final List<Video> videos;
  final ValueChanged<Video> onOpen;

  /// Called with the index of an item when it receives focus (used to trigger
  /// pagination slightly before the end of the list).
  final ValueChanged<int>? onItemFocus;

  /// Lets a page move focus to the first card (e.g. when search results land).
  final FocusNode? firstItemFocusNode;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // The gap is deliberately wider than the focus ring + scale overflow.
        final gap = context.s(Gaps.lg);
        final width = constraints.crossAxisExtent - padding.horizontal;
        final cardWidth = ((width - gap * (kVideoGridColumns - 1)) /
                kVideoGridColumns)
            .clamp(0.0, double.infinity)
            .toDouble();

        return SliverPadding(
          padding: padding,
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: kVideoGridColumns,
              crossAxisSpacing: gap,
              mainAxisSpacing: context.s(Gaps.lg),
              mainAxisExtent: VideoCardMetrics.height(context, cardWidth),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final video = videos[index];
                return VideoCard(
                  key: ValueKey<String>(video.id),
                  video: video,
                  focusNode: index == 0 ? firstItemFocusNode : null,
                  onFocus: onItemFocus == null ? null : () => onItemFocus!(index),
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
