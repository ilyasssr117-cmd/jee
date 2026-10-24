import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import '../playback_progress.dart';
import '../tv_focusable.dart';
import 'video_artwork.dart';
import 'video_meta.dart';

/// Layout maths shared by every place that shows [VideoCard]s, so a card's
/// height is always known up-front (no overflow, no layout jumps).
abstract final class VideoCardMetrics {
  static const double _titleSize = 17;
  static const double _titleHeight = 1.25;
  static const double _metaSize = 15;
  static const double _metaHeight = 1.3;
  static const double _gapAfterThumb = 10;
  static const double _gapAfterTitle = 4;

  /// Total card height for a given width (16:9 thumbnail + two title lines +
  /// one metadata line).
  static double height(BuildContext context, double width) {
    final thumb = width * 9 / 16;
    final text = _gapAfterThumb +
        _titleSize * _titleHeight * 2 +
        _gapAfterTitle +
        _metaSize * _metaHeight +
        4; // slack for rounding
    return thumb + context.s(text);
  }
}

/// Poster-style video card: 16:9 thumbnail, two-line title, one metadata line.
///
/// Focus draws a ring *outside* the thumbnail (paint only) and scales the card
/// slightly. Nothing about focus changes layout, and the surrounding grid gap
/// is larger than the ring so it is never clipped.
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onFocus,
    this.focusNode,
    this.autofocus = false,
  });

  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onFocus;
  final FocusNode? focusNode;
  final bool autofocus;

  static const double _ringWidth = 3;

  @override
  Widget build(BuildContext context) {
    final radius = context.s(Radii.card);
    final ring = context.s(_ringWidth);
    final progress = PlaybackProgress.instance.fraction(video.id);

    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      onFocus: onFocus,
      scale: 1.05,
      scrollAlignment: 0.38,
      semanticLabel: [
        video.title,
        if (video.duration.isNotEmpty) video.duration,
        if (video.likes.isNotEmpty) '${video.likes} liked',
        if (video.views.isNotEmpty) video.views,
      ].join(', '),
      builder: (context, focused) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoArtwork(video: video),
                          if (video.duration.isNotEmpty)
                            Positioned(
                              right: context.s(8),
                              bottom: context.s(progress == null ? 8 : 12),
                              child: _DurationBadge(text: video.duration),
                            ),
                          if (progress != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _ProgressBar(
                                fraction: progress,
                                height: context.s(4),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Focus ring drawn outside the card bounds.
                  Positioned(
                    left: -ring,
                    top: -ring,
                    right: -ring,
                    bottom: -ring,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: focused ? 1 : 0,
                        duration: Motion.quick,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius + ring),
                            border: Border.all(
                              color: AppColors.focusRing,
                              width: ring,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.s(10)),
            // Reserve exactly two lines so metadata aligns across the row.
            SizedBox(
              height: context.s(17 * 1.25 * 2),
              child: AnimatedDefaultTextStyle(
                duration: Motion.quick,
                style: AppText.cardTitle.copyWith(
                  color: focused
                      ? AppColors.textPrimary
                      : AppColors.textPrimary.withValues(alpha: 0.82),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                child: Text(video.title),
              ),
            ),
            SizedBox(height: context.s(4)),
            VideoMetaLine(video: video),
          ],
        );
      },
    );
  }
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(context.s(6)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(7),
          vertical: context.s(3),
        ),
        child: Text(
          text,
          maxLines: 1,
          style: AppText.caption.copyWith(
            fontSize: 14,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction, required this.height});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0x80000000)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction,
            child: const DecoratedBox(
              decoration: BoxDecoration(color: AppColors.accent),
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}
