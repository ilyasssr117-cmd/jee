import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'favorites_store.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/state_views.dart';
import 'widgets/video_artwork.dart';
import 'widgets/video_grid.dart';
import 'widgets/video_meta.dart';

class VideoDetailsPage extends StatefulWidget {
  const VideoDetailsPage({super.key, required this.video, this.queue});

  final Video video;

  /// The list this video was opened from; Autoplay Next continues through it.
  final List<Video>? queue;

  @override
  State<VideoDetailsPage> createState() => _VideoDetailsPageState();
}

class _VideoDetailsPageState extends State<VideoDetailsPage> {
  late Future<List<Video>> _relatedFuture;
  bool _preparing = false;
  String? _playError;

  @override
  void initState() {
    super.initState();
    _relatedFuture = videoRepository.getRelated(widget.video);
  }

  void _reloadRelated() {
    setState(() => _relatedFuture = videoRepository.getRelated(widget.video));
  }

  Future<void> _play({bool fromStart = false}) async {
    if (_preparing) return;
    final progress = PlaybackProgress.instance;
    final startAt = fromStart ? null : progress.resumePosition(widget.video.id);
    if (fromStart) progress.clear(widget.video.id);

    setState(() {
      _preparing = true;
      _playError = null;
    });
    final error = await launchPlayer(
      context,
      widget.video,
      startAt: startAt,
      queue: widget.queue,
    );
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _playError = error;
    });
  }

  /// Replaces this page instead of stacking another one on top, so browsing
  /// related videos can't build an unbounded route stack and BACK returns to
  /// where the viewer came from.
  void _openRelated(Video video, List<Video> related) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: related),
      ),
    );
  }

  String _formatResume(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        cacheExtent: MediaQuery.sizeOf(context).height,
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(margin)),
          SliverToBoxAdapter(child: _buildRelatedTitle(margin)),
          _buildRelated(margin),
          SliverToBoxAdapter(
            child: SizedBox(height: Gaps.xl + context.safe.bottom),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    final size = MediaQuery.sizeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final resume = PlaybackProgress.instance.resumePosition(video.id);
    final meta = VideoMetaLine(
      video: video,
      style: AppText.caption.copyWith(color: AppColors.textSecondary),
      showDuration: true,
      showDate: true,
      fallbackToCategory: false,
    );

    return SizedBox(
      height: math.min(size.height * 0.5, 460.0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoArtwork(video: video, showLabel: false),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [Color(0x330B0D12), Color(0xE60B0D12)]
                    : const [Color(0x18FFFFFF), Color(0xEEF5F6FA)],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [Color(0x000B0D12), Color(0xFF0B0D12)]
                    : const [Color(0x00F5F6FA), Color(0xFFF5F6FA)],
                stops: const [0.55, 1],
              ),
            ),
          ),
          Positioned(
            left: margin,
            right: margin,
            bottom: Gaps.md,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (video.category.isNotEmpty)
                  Text(
                    video.category.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.overline,
                  ),
                const SizedBox(height: 6),
                Text(
                  video.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display.copyWith(fontSize: 22),
                ),
                if (meta.hasContent) ...[
                  const SizedBox(height: Gaps.sm),
                  meta,
                ],
                if (video.description.isNotEmpty) ...[
                  const SizedBox(height: Gaps.sm),
                  Text(
                    video.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontSize: 13),
                  ),
                ],
                const SizedBox(height: Gaps.md),
                Wrap(
                  spacing: Gaps.sm,
                  runSpacing: Gaps.sm,
                  children: [
                    AppButton(
                      label: resume != null
                          ? 'Resume ${_formatResume(resume)}'
                          : 'Play',
                      icon: Icons.play_arrow_rounded,
                      loading: _preparing,
                      onPressed: _play,
                    ),
                    if (resume != null)
                      AppButton(
                        label: 'Start over',
                        icon: Icons.replay_rounded,
                        style: AppButtonStyle.secondary,
                        onPressed: () => _play(fromStart: true),
                      ),
                    _buildFavoriteButton(),
                  ],
                ),
                if (_playError != null) ...[
                  const SizedBox(height: Gaps.sm),
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: AppColors.error,
                      ),
                      const SizedBox(width: Gaps.sm),
                      Flexible(
                        child: Text(
                          _playError!,
                          style: AppText.body.copyWith(color: AppColors.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: margin,
            top: context.safe.top + Gaps.sm,
            child: const PageBackButton(),
          ),
        ],
      ),
    );
  }

  /// Star toggle. Active (gold, filled star) when the video is a favourite.
  Widget _buildFavoriteButton() {
    return ListenableBuilder(
      listenable: FavoritesStore.instance,
      builder: (context, _) {
        final active = FavoritesStore.instance.isFavorite(widget.video.id);
        return AppButton(
          label: active ? 'Favorited' : 'Favorite',
          icon: active ? Icons.star_rounded : Icons.star_border_rounded,
          iconColor: active ? AppColors.star : null,
          style: AppButtonStyle.secondary,
          onPressed: () {
            final nowFavorite = FavoritesStore.instance.toggle(widget.video);
            Haptics.play(nowFavorite ? Haptic.medium : Haptic.light);
          },
        );
      },
    );
  }

  Widget _buildRelatedTitle(double margin) {
    return FutureBuilder<List<Video>>(
      future: _relatedFuture,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        // Nothing to recommend: hide the title with the section.
        if (!waiting && !snapshot.hasError && (snapshot.data ?? const []).isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(margin, Gaps.md, margin, Gaps.md),
          child: Text('More like this', style: AppText.headline),
        );
      },
    );
  }

  /// Related videos as a grid (2 per row) under the title, not one long strip.
  Widget _buildRelated(double margin) {
    final padding = EdgeInsets.symmetric(horizontal: margin);
    return FutureBuilder<List<Video>>(
      future: _relatedFuture,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        final related = snapshot.data ?? const <Video>[];

        final Widget content;
        if (snapshot.hasError) {
          content = SliverToBoxAdapter(
            key: const ValueKey<String>('error'),
            child: Padding(
              padding: padding,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Couldn\u2019t load related videos.',
                      style: AppText.body,
                    ),
                  ),
                  AppButton(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    style: AppButtonStyle.secondary,
                    onPressed: _reloadRelated,
                  ),
                ],
              ),
            ),
          );
        } else if (waiting) {
          content = SliverSkeletonGrid(
            key: const ValueKey<String>('loading'),
            count: 4,
            padding: padding,
          );
        } else {
          content = SliverVideoGrid(
            key: const ValueKey<String>('items'),
            videos: related,
            padding: padding,
            onOpen: (video) => _openRelated(video, related),
          );
        }

        return content;
      },
    );
  }
}
