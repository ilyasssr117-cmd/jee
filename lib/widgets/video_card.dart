import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorites_store.dart';
import '../models.dart';
import '../playback_progress.dart';
import '../preview_manager.dart';
import '../touch.dart';
import 'video_artwork.dart';
import 'video_meta.dart';
import 'video_preview.dart';

abstract final class VideoCardMetrics {
  static const double titleSize = 13.5;
  static const double titleHeight = 1.25;
  static const double metaSize = 12;
  static const double metaHeight = 1.3;
  static const double gapAfterThumb = 8;
  static const double gapAfterTitle = 3;

  static double textBlock(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return gapAfterThumb +
        scaler.scale(titleSize) * titleHeight * 2 +
        gapAfterTitle +
        scaler.scale(metaSize) * metaHeight +
        4;
  }

  static double height(BuildContext context, double width) =>
      width * 9 / 16 + textBlock(context);
}

class VideoCard extends StatelessWidget {
  const VideoCard({super.key, required this.video, required this.onTap});

  final Video video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final completed = PlaybackProgress.instance.isCompleted(video.id);
    final progress =
        completed ? null : PlaybackProgress.instance.fraction(video.id);

    return Pressable(
      pressedScale: 0.97,
      semanticLabel: [
        video.title,
        if (completed) 'watched',
        if (video.duration.isNotEmpty) video.duration,
        if (video.likes.isNotEmpty) '${video.likes} liked',
        if (video.views.isNotEmpty) video.views,
      ].join(', '),
      onTap: () {
        PreviewManager.instance.stopNow(fade: false);
        onTap();
      },
      onLongPress: () => PreviewManager.instance.requestPreview(video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoArtwork(video: video),
                  PreviewSlot(video: video),
                  if (completed)
                    const Positioned(
                      left: 6,
                      top: 6,
                      child: _Badge(
                        icon: Icons.check_rounded,
                        background: AppColors.accentStrong,
                        color: Colors.white,
                      ),
                    ),
                  if (video.duration.isNotEmpty)
                    Positioned(
                      right: 6,
                      bottom: progress == null ? 6 : 9,
                      child: DurationBadge(text: video.duration),
                    ),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _ProgressBar(fraction: progress),
                    ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: _FavoriteButton(video: video),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: VideoCardMetrics.gapAfterThumb),
          SizedBox(
            height: MediaQuery.textScalerOf(context)
                    .scale(VideoCardMetrics.titleSize) *
                VideoCardMetrics.titleHeight *
                2,
            child: Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.cardTitle,
            ),
          ),
          const SizedBox(height: VideoCardMetrics.gapAfterTitle),
          VideoMetaLine(video: video, showDate: true),
        ],
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.video});

  final Video video;

  @override
  Widget build(BuildContext context) {
    final store = FavoritesStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final active = store.isFavorite(video.id);
        return Pressable(
          semanticLabel: active ? 'Remove from favorites' : 'Add to favorites',
          haptic: Haptic.none,
          pressedScale: 0.8,
          onTap: () {
            final nowFavorite = store.toggle(video);
            Haptics.play(nowFavorite ? Haptic.medium : Haptic.light);
          },
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: AnimatedContainer(
                duration: Motion.normal,
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? const Color(0xCC000000) : const Color(0x73000000),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.elasticOut,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    active ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    key: ValueKey<bool>(active),
                    size: 20,
                    color: active ? AppColors.accent : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.background,
    required this.color,
  });

  final IconData icon;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: SizedBox(
        width: 20,
        height: 20,
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}

class DurationBadge extends StatelessWidget {
  const DurationBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          text,
          maxLines: 1,
          style: AppText.caption.copyWith(
            fontSize: 11,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
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
