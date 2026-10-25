import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'app_button.dart';
import 'state_views.dart';
import 'video_artwork.dart';
import 'video_meta.dart';

/// Top of the home page: brand bar + featured video.
///
/// The hero lives inside the page's single scroll view, so it scrolls away
/// naturally and never takes screen space permanently.
class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.video,
    required this.loading,
    required this.playLabel,
    required this.playBusy,
    required this.onPlay,
    required this.onDetails,
  });

  /// Featured video, or null while loading / when there is nothing to show.
  final Video? video;
  final bool loading;
  final String playLabel;
  final bool playBusy;
  final VoidCallback onPlay;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final topPad = context.safe.top + Gaps.sm;
    const topBar = _TopBar();

    // Error / empty: keep only the brand bar so the status view has room.
    if (video == null && !loading) {
      return Padding(
        padding: EdgeInsets.fromLTRB(margin, topPad, margin, 0),
        child: topBar,
      );
    }

    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.height * 0.42, 380.0);
    final featured = video;

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (featured != null)
            VideoArtwork(video: featured, showLabel: false)
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1B2033), AppColors.background],
                ),
              ),
            ),
          // Scrims: top for the brand bar, bottom to blend into the page.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x330B0D12), Color(0xE60B0D12)],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB30B0D12), Color(0x000B0D12)],
                stops: [0, 0.3],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x000B0D12), AppColors.background],
                stops: [0.6, 1],
              ),
            ),
          ),
          Positioned(left: margin, right: margin, top: topPad, child: topBar),
          Positioned(
            left: margin,
            right: margin,
            bottom: Gaps.md,
            child: AnimatedSwitcher(
              duration: Motion.fade,
              child: featured == null
                  ? const _HeroSkeleton(key: ValueKey<String>('skeleton'))
                  : _HeroDetails(
                      key: ValueKey<String>(featured.id),
                      video: featured,
                      playLabel: playLabel,
                      playBusy: playBusy,
                      onPlay: onPlay,
                      onDetails: onDetails,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.accentStrong,
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 22,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: Gaps.sm),
        Text(
          'TV TUBE',
          style: AppText.label.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
      ],
    );
  }
}

class _HeroDetails extends StatelessWidget {
  const _HeroDetails({
    super.key,
    required this.video,
    required this.playLabel,
    required this.playBusy,
    required this.onPlay,
    required this.onDetails,
  });

  final Video video;
  final String playLabel;
  final bool playBusy;
  final VoidCallback onPlay;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FEATURED', style: AppText.overline),
        const SizedBox(height: 6),
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.display.copyWith(fontSize: 22),
        ),
        const SizedBox(height: Gaps.sm),
        VideoMetaLine(
          video: video,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
          showDuration: true,
          showCategory: true,
        ),
        const SizedBox(height: Gaps.md),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(
              label: playLabel,
              icon: Icons.play_arrow_rounded,
              loading: playBusy,
              onPressed: onPlay,
            ),
            const SizedBox(width: Gaps.sm),
            AppButton(
              label: 'Details',
              icon: Icons.info_outline_rounded,
              style: AppButtonStyle.secondary,
              onPressed: onDetails,
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const SkeletonPulse(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBlock(width: 70, height: 11),
          SizedBox(height: 10),
          SkeletonBlock(width: 260, height: 22),
          SizedBox(height: 8),
          SkeletonBlock(width: 180, height: 22),
          SizedBox(height: Gaps.md),
          SkeletonBlock(width: 150, height: 40, radius: Radii.button),
        ],
      ),
    );
  }
}
