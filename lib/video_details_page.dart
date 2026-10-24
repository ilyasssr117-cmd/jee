import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'video_repository.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';
import 'widgets/video_artwork.dart';
import 'widgets/video_card.dart';
import 'widgets/video_grid.dart';
import 'widgets/video_meta.dart';

class VideoDetailsPage extends StatefulWidget {
  const VideoDetailsPage({super.key, required this.video});

  final Video video;

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
    final error = await launchPlayer(context, widget.video, startAt: startAt);
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
  void _openRelated(Video video) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(builder: (_) => VideoDetailsPage(video: video)),
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
    final margin = context.s(Gaps.screenH);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        cacheExtent: MediaQuery.sizeOf(context).height,
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(margin)),
          SliverToBoxAdapter(child: _buildRelated(margin)),
          SliverToBoxAdapter(child: SizedBox(height: context.s(Gaps.xxl))),
        ],
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    final size = MediaQuery.sizeOf(context);
    final resume = PlaybackProgress.instance.resumePosition(video.id);
    final meta = VideoMetaLine(
      video: video,
      style: AppText.body,
      showDuration: true,
      showDate: true,
      fallbackToCategory: false,
    );

    return SizedBox(
      height: size.height * 0.68,
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoArtwork(video: video, showLabel: false),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFA0B0D12), Color(0xD10B0D12), Color(0x330B0D12)],
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
            width: size.width * 0.52,
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
                  style: AppText.display.copyWith(fontSize: 40),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
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
                    if (resume != null) ...[
                      SizedBox(width: context.s(Gaps.md)),
                      TvButton(
                        label: 'Start over',
                        icon: Icons.replay_rounded,
                        style: TvButtonStyle.secondary,
                        onPressed: () => _play(fromStart: true),
                      ),
                    ],
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
        ],
      ),
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

        final gap = context.s(Gaps.lg);
        final width = MediaQuery.sizeOf(context).width;
        final cardWidth = ((width - margin * 2 - gap * (kVideoGridColumns - 1)) /
                kVideoGridColumns)
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
            itemCount: kVideoGridColumns,
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
                  onTap: () => _openRelated(item),
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
