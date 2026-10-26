import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../history_store.dart';
import '../models.dart';
import '../playback_progress.dart';
import '../touch.dart';
import 'video_artwork.dart';

/// "Continue watching": the videos you started and didn't finish. One tap
/// resumes at the exact second.
class ContinueRow extends StatelessWidget {
  const ContinueRow({super.key, required this.onPlay});

  final void Function(Video video) onPlay;

  static const double _cardWidth = 168;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: HistoryStore.instance,
      builder: (context, _) {
        final progress = PlaybackProgress.instance;
        final videos = <Video>[];
        for (final entry in HistoryStore.instance.items) {
          if (videos.length >= 8) break;
          final id = entry.video.id;
          if (progress.isCompleted(id)) continue;
          final fraction = progress.fraction(id);
          if (fraction == null || fraction < 0.01) continue;
          videos.add(entry.video);
        }
        if (videos.isEmpty) return const SizedBox.shrink();

        final margin = context.hMargin;
        final scaler = MediaQuery.textScalerOf(context);
        final height = _cardWidth * 9 / 16 +
            8 +
            scaler.scale(13.5) * 1.25 * 2 +
            6;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(margin, Gaps.md, margin, Gaps.md),
              child: Text('Continue watching', style: AppText.headline),
            ),
            SizedBox(
              height: height,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: margin),
                itemCount: videos.length,
                separatorBuilder: (_, __) => const SizedBox(width: Gaps.md),
                itemBuilder: (context, index) => _ContinueCard(
                  video: videos[index],
                  onTap: () => onPlay(videos[index]),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.video, required this.onTap});

  final Video video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fraction = PlaybackProgress.instance.fraction(video.id) ?? 0;
    return Pressable(
      semanticLabel: 'Continue ${video.title}',
      pressedScale: 0.96,
      onTap: onTap,
      child: SizedBox(
        width: ContinueRow._cardWidth,
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
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0x73000000),
                        ),
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 24,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        height: 3,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(color: Color(0x80000000)),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: fraction.clamp(0.0, 1.0).toDouble(),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(color: AppColors.accent),
                                child: SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.cardTitle,
            ),
          ],
        ),
      ),
    );
  }
}
