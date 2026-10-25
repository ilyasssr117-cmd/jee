import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'favorites_store.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'video_repository.dart';
import 'widgets/back_button.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';
import 'widgets/video_artwork.dart';
import 'widgets/video_card.dart';
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
  final FocusNode _playNode = FocusNode(debugLabel: 'Details play');
  late Future<List<Video>> _relatedFuture;
  bool _preparing = false;
  String? _playError;

  @override
  void initState() {
    super.initState();
    _relatedFuture = videoRepository.getRelated(widget.video);
  }

  @override
  void dispose() {
    _playNode.dispose();
    super.dispose();
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
    _restoreFocusIfLost();
  }

  /// Replaces this page instead of stacking another one on top, so browsing
  /// related videos can't build an unbounded route stack (each holding its own
  /// images and futures) and BACK returns to where the viewer came from.
  void _openRelated(Video video, List<Video> related) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: related),
      ),
    );
  }

  void _restoreFocusIfLost() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) {
        _playNode.requestFocus();
      }
    });
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
          SliverToBoxAdapter(child: _buildRelated(margin)),
          SliverToBoxAdapter(
            child: SizedBox(height: context.s(Gaps.xxl) + context.safe.bottom),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    final size = MediaQuery.sizeOf(context);
    final phone = context.isPhone;
    final resume = PlaybackProgress.instance.resumePosition(video.id);
    final meta = VideoMetaLine(
      video: video,
      style: AppText.body,
      showDuration: true,
      showDate: true,
      fallbackToCategory: false,
    );

    return SizedBox(
      height: size.height * (phone ? 0.6 : 0.68),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoArtwork(video: video, showLabel: false),
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
                        Color(0xFA0B0D12),
                        Color(0xD10B0D12),
                        Color(0x330B0D12),
                      ],
                      stops: [0, 0.5, 1],
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
          Positioned(
            left: margin,
            bottom: context.s(Gaps.lg),
            width: phone ? size.width - margin * 2 : size.width * 0.52,
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
                SizedBox(height: context.s(10)),
                Text(
                  video.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.display.copyWith(fontSize: phone ? 28 : 40),
                ),
                if (meta.hasContent) ...[
                  SizedBox(height: context.s(12)),
                  meta,
                ],
                if (video.description.isNotEmpty) ...[
                  SizedBox(height: context.s(Gaps.md)),
                  Text(
                    video.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body,
                  ),
                ],
                SizedBox(height: context.s(Gaps.lg)),
                // Wrap (not Row): Resume + Start over + Favorites can be wider
                // than this column on smaller screens.
                Wrap(
                  spacing: context.s(Gaps.md),
                  runSpacing: context.s(Gaps.md),
                  children: [
                    TvButton(
                      label: resume != null
                          ? 'Resume from ${_formatResume(resume)}'
                          : 'Play',
                      icon: Icons.play_arrow_rounded,
                      autofocus: true,
                      focusNode: _playNode,
                      loading: _preparing,
                      onPressed: _play,
                    ),
                    if (resume != null)
                      TvButton(
                        label: 'Start over',
                        icon: Icons.replay_rounded,
                        style: TvButtonStyle.secondary,
                        onPressed: () => _play(fromStart: true),
                      ),
                    _buildFavoriteButton(),
                  ],
                ),
                if (_playError != null) ...[
                  SizedBox(height: context.s(Gaps.md)),
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: context.s(22),
                        color: AppColors.error,
                      ),
                      SizedBox(width: context.s(Gaps.sm)),
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
          // Back: always visible, touch or remote.
          Positioned(
            left: margin,
            top: context.s(Gaps.screenV) + context.safe.top,
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
        return TvButton(
          label: active ? 'Favorited' : 'Add to Favorites',
          icon: active ? Icons.star_rounded : Icons.star_border_rounded,
          iconColor: active ? AppColors.star : null,
          style: TvButtonStyle.secondary,
          onPressed: () => FavoritesStore.instance.toggle(widget.video),
        );
      },
    );
  }

  Widget _buildRelated(double margin) {
    return FutureBuilder<List<Video>>(
      future: _relatedFuture,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        final related = snapshot.data ?? const <Video>[];

        // Nothing to recommend: hide the section instead of showing noise.
        if (!waiting && !snapshot.hasError && related.isEmpty) {
          return const SizedBox.shrink();
        }

        final columns = videoGridColumns(context);
        final gap = context.s(Gaps.lg);
        final width = MediaQuery.sizeOf(context).width;
        final cardWidth = ((width - margin * 2 - gap * (columns - 1)) /
                columns)
            .clamp(0.0, double.infinity)
            .toDouble();
        final cardHeight = VideoCardMetrics.height(context, cardWidth);
        // Extra vertical room so the focus ring and scale are never clipped.
        final rowHeight = cardHeight + context.s(Gaps.lg);

        Widget row;
        if (snapshot.hasError) {
          row = Padding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            child: Row(
              children: [
                Text('Couldn\u2019t load related videos.', style: AppText.body),
                SizedBox(width: context.s(Gaps.md)),
                TvButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  style: TvButtonStyle.secondary,
                  onPressed: _reloadRelated,
                ),
              ],
            ),
          );
        } else if (waiting) {
          row = ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: margin, vertical: context.s(12)),
            itemCount: columns,
            separatorBuilder: (_, __) => SizedBox(width: gap),
            itemBuilder: (_, __) =>
                SizedBox(width: cardWidth, child: const SkeletonCard()),
          );
        } else {
          row = ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: EdgeInsets.symmetric(horizontal: margin, vertical: context.s(12)),
            itemCount: related.length,
            separatorBuilder: (_, __) => SizedBox(width: gap),
            itemBuilder: (context, index) {
              final item = related[index];
              return SizedBox(
                width: cardWidth,
                child: VideoCard(
                  key: ValueKey<String>(item.id),
                  video: item,
                  onTap: () => _openRelated(item, related),
                ),
              );
            },
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(margin, 0, margin, context.s(Gaps.sm)),
              child: Text('More like this', style: AppText.headline),
            ),
            SizedBox(
              height: snapshot.hasError ? context.s(72) : rowHeight,
              child: row,
            ),
          ],
        );
      },
    );
  }
}
