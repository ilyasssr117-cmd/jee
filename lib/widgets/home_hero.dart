import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'app_button.dart';
import 'state_views.dart';
import 'video_artwork.dart';
import 'video_meta.dart';

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
    if (video == null && !loading) {
      return Padding(
        padding: EdgeInsets.fromLTRB(margin, topPad, margin, Gaps.md),
        child: const _TopBar(),
      );
    }

    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.height * 0.48, 450.0).toDouble();
    final featured = video;

    return Padding(
      padding: EdgeInsets.fromLTRB(margin, topPad, margin, Gaps.sm),
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: OnDark.surface),
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
                        colors: [Color(0xFF401D27), OnDark.background],
                      ),
                    ),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x4D080A0F),
                        Color(0x08080A0F),
                        Color(0xF2080A0F),
                      ],
                      stops: [0, 0.35, 1],
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [Color(0x32080A0F), Colors.transparent],
                    ),
                  ),
                ),
                const Positioned(
                  left: 16,
                  top: 16,
                  child: _TopBar(),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 18,
                  child: AnimatedSwitcher(
                    duration: Motion.fade,
                    switchInCurve: Curves.easeOutCubic,
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
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 7, 13, 7),
          decoration: BoxDecoration(
            color: const Color(0x6B101319),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.accent, AppColors.accentStrong],
                  ),
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(Icons.play_arrow_rounded, size: 20, color: Colors.white),
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'FLOW',
                style: darkText.label.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.8,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 5),
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              'FEATURED FOR YOU',
              style: darkText.overline.copyWith(
                color: const Color(0xFFFF929A),
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: darkText.display.copyWith(
            fontSize: 25,
            height: 1.08,
            letterSpacing: -0.7,
            color: Colors.white,
            shadows: const [
              Shadow(color: Color(0x88000000), blurRadius: 18, offset: Offset(0, 3)),
            ],
          ),
        ),
        const SizedBox(height: Gaps.sm),
        VideoMetaLine(
          video: video,
          style: darkText.caption.copyWith(
            color: const Color(0xFFD6D8DE),
            fontWeight: FontWeight.w600,
          ),
          showDuration: true,
          showCategory: true,
        ),
        const SizedBox(height: Gaps.lg),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppButton(
              label: playLabel,
              icon: Icons.play_arrow_rounded,
              loading: playBusy,
              onDark: true,
              onPressed: onPlay,
            ),
            const SizedBox(width: Gaps.sm),
            AppButton(
              label: 'Details',
              icon: Icons.info_outline_rounded,
              style: AppButtonStyle.secondary,
              onDark: true,
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
          SkeletonBlock(width: 104, height: 11, color: OnDark.surfaceHigh),
          SizedBox(height: 12),
          SkeletonBlock(width: 260, height: 25, color: OnDark.surfaceHigh),
          SizedBox(height: 8),
          SkeletonBlock(width: 190, height: 25, color: OnDark.surfaceHigh),
          SizedBox(height: Gaps.lg),
          SkeletonBlock(
            width: 156,
            height: 44,
            radius: Radii.button,
            color: OnDark.surfaceHigh,
          ),
        ],
      ),
    );
  }
}
