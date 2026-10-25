import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'state_views.dart';
import 'tv_button.dart';
import 'video_artwork.dart';
import 'video_meta.dart';

/// Top of the home page: brand bar + featured video.
///
/// The hero lives inside the page's single scroll view, so it scrolls away
/// naturally and never takes screen space permanently. Its buttons ask the page
/// to scroll back to the top when focused so the whole hero is always visible.
class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.video,
    required this.loading,
    required this.playLabel,
    required this.playBusy,
    required this.playNode,
    required this.onPlay,
    required this.onDetails,
    required this.onChildFocus,
  });

  /// Featured video, or null while loading / when there is nothing to show.
  final Video? video;
  final bool loading;
  final String playLabel;
  final bool playBusy;
  final FocusNode playNode;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  final VoidCallback onChildFocus;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final phone = context.isPhone;
    final topPad = context.s(Gaps.screenV) + context.safe.top;
    const topBar = _TopBar();

    // Error / empty: keep only the brand bar so the status view has room.
    if (video == null && !loading) {
      return Padding(
        padding: EdgeInsets.fromLTRB(margin, topPad, margin, 0),
        child: topBar,
      );
    }

    final height = MediaQuery.sizeOf(context).height * (phone ? 0.46 : 0.58);
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
          // Scrims: left for text, top for the brand bar, bottom to blend into
          // the page background.
          // Phone: the text spans the full width, so the scrim is vertical.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: phone
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x330B0D12), Color(0xE60B0D12)],
                    )
                  : const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xF50B0D12),
                        Color(0xC70B0D12),
                        Color(0x260B0D12),
                      ],
                      stops: [0, 0.45, 1],
                    ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB30B0D12), Color(0x000B0D12)],
                stops: [0, 0.28],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x000B0D12), AppColors.background],
                stops: [0.55, 1],
              ),
            ),
          ),
          Positioned(
            left: margin,
            right: margin,
            top: topPad,
            child: topBar,
          ),
          Positioned(
            left: margin,
            bottom: context.s(Gaps.xl),
            width: phone
                ? MediaQuery.sizeOf(context).width - margin * 2
                : MediaQuery.sizeOf(context).width * 0.5,
            child: featured == null
                ? const _HeroSkeleton()
                : _HeroDetails(
                    video: featured,
                    playLabel: playLabel,
                    playBusy: playBusy,
                    playNode: playNode,
                    onPlay: onPlay,
                    onDetails: onDetails,
                    onFocus: onChildFocus,
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
          width: context.s(44),
          height: context.s(44),
          decoration: BoxDecoration(
            color: AppColors.accentStrong,
            borderRadius: BorderRadius.circular(context.s(12)),
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            size: context.s(32),
            color: Colors.white,
          ),
        ),
        SizedBox(width: context.s(Gaps.md - 2)),
        Text(
          'TV TUBE',
          style: AppText.title.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

class _HeroDetails extends StatelessWidget {
  const _HeroDetails({
    required this.video,
    required this.playLabel,
    required this.playBusy,
    required this.playNode,
    required this.onPlay,
    required this.onDetails,
    required this.onFocus,
  });

  final Video video;
  final String playLabel;
  final bool playBusy;
  final FocusNode playNode;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FEATURED', style: AppText.overline),
        SizedBox(height: context.s(10)),
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.isPhone
              ? AppText.display.copyWith(fontSize: 30)
              : AppText.display,
        ),
        SizedBox(height: context.s(12)),
        VideoMetaLine(
          video: video,
          style: AppText.body,
          showDuration: true,
          showCategory: true,
        ),
        SizedBox(height: context.s(Gaps.lg)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvButton(
              label: playLabel,
              icon: Icons.play_arrow_rounded,
              focusNode: playNode,
              loading: playBusy,
              scrollAlignment: null,
              onFocus: onFocus,
              onPressed: onPlay,
            ),
            SizedBox(width: context.s(Gaps.md)),
            TvButton(
              label: 'Details',
              icon: Icons.info_outline_rounded,
              style: TvButtonStyle.secondary,
              scrollAlignment: null,
              onFocus: onFocus,
              onPressed: onDetails,
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBlock(width: context.s(90), height: context.s(14)),
          SizedBox(height: context.s(14)),
          SkeletonBlock(width: context.s(context.isPhone ? 300 : 520), height: context.s(40)),
          SizedBox(height: context.s(12)),
          SkeletonBlock(width: context.s(context.isPhone ? 200 : 300), height: context.s(40)),
          SizedBox(height: context.s(Gaps.lg)),
          SkeletonBlock(width: context.s(190), height: context.s(52), radius: Radii.button),
        ],
      ),
    );
  }
}
