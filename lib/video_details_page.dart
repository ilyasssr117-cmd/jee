import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'download_store.dart';
import 'favorites_store.dart';
import 'model_page.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'request_cache.dart';
import 'save_video_to_photos.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/dialogs.dart';
import 'widgets/state_views.dart';
import 'widgets/video_artwork.dart';
import 'widgets/video_grid.dart';
import 'widgets/video_meta.dart';

class VideoDetailsPage extends StatefulWidget {
  const VideoDetailsPage({super.key, required this.video, this.queue});

  final Video video;

  final List<Video>? queue;

  @override
  State<VideoDetailsPage> createState() => _VideoDetailsPageState();
}

class _VideoDetailsPageState extends State<VideoDetailsPage> {
  late Future<List<Video>> _relatedFuture;
  late Future<List<ModelRef>> _modelsFuture;
  final ScrollController _scroll = ScrollController();

  final ValueNotifier<bool> _overHeader = ValueNotifier<bool>(true);
  double _headerLimit = 200;
  bool _preparing = false;
  String? _playError;

  @override
  void initState() {
    super.initState();
    _relatedFuture = _loadRelated();
    _modelsFuture = _loadModels();
    _scroll.addListener(() {
      final over = !_scroll.hasClients || _scroll.offset < _headerLimit;
      if (over != _overHeader.value) _overHeader.value = over;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _overHeader.dispose();
    super.dispose();
  }

  Future<List<Video>> _loadRelated() => relatedCache.fetch(
        widget.video.id,
        () => videoRepository.getRelated(widget.video),
      );

  Future<List<ModelRef>> _loadModels() => modelsCache.fetch(
        widget.video.id,
        () => videoRepository.getVideoModels(widget.video),
      );

  void _openModel(ModelRef model) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ModelPage(model: model)),
    );
  }

  void _reloadRelated() {
    relatedCache.clear();
    setState(() => _relatedFuture = _loadRelated());
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
    _headerLimit = _headerHeight(MediaQuery.sizeOf(context)) - context.safe.top - 30;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    return ValueListenableBuilder<bool>(
      valueListenable: _overHeader,
      builder: (context, overHeader, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: darkMode || overHeader
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: child!,
      ),
      child: Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        controller: _scroll,
        scrollCacheExtent: ScrollCacheExtent.pixels(
          MediaQuery.sizeOf(context).height,
        ),
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(margin)),
          SliverToBoxAdapter(child: _buildModels(margin)),
          SliverToBoxAdapter(child: _buildRelatedTitle(margin)),
          _buildRelated(margin),
          SliverToBoxAdapter(
            child: SizedBox(height: Gaps.xl + context.safe.bottom),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    final size = MediaQuery.sizeOf(context);
    final resume = PlaybackProgress.instance.resumePosition(video.id);
    final meta = VideoMetaLine(
      video: video,
      style: darkText.caption.copyWith(color: OnDark.textSecondary),
      showDuration: true,
      showDate: true,
      fallbackToCategory: false,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: _headerHeight(size)),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Stack(
        alignment: Alignment.bottomLeft,
        children: [
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                VideoArtwork(video: video, showLabel: false),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x330B0D12), Color(0xE60B0D12)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              margin,
              context.safe.top + Gaps.sm + kMinTapSize + Gaps.md,
              margin,
              Gaps.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (video.category.isNotEmpty)
                  Text(
                    video.category.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: darkText.overline,
                  ),
                const SizedBox(height: 6),
                Text(
                  video.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: darkText.display.copyWith(fontSize: 22),
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
                    style: darkText.body.copyWith(fontSize: 13),
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
                      onDark: true,
                      onPressed: _play,
                    ),
                    if (resume != null)
                      AppButton(
                        label: 'Start over',
                        icon: Icons.replay_rounded,
                        style: AppButtonStyle.secondary,
                        onDark: true,
                        onPressed: () => _play(fromStart: true),
                      ),
                    _buildFavoriteButton(),
                    _buildDownloadButton(),
                  ],
                ),
                if (_playError != null) ...[
                  const SizedBox(height: Gaps.sm),
                  Row(
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: OnDark.error,
                      ),
                      const SizedBox(width: Gaps.sm),
                      Flexible(
                        child: Text(
                          _playError!,
                          style: darkText.body.copyWith(color: OnDark.error),
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
      ),
    );
  }

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
          onDark: true,
          onPressed: () {
            final nowFavorite = FavoritesStore.instance.toggle(widget.video);
            Haptics.play(nowFavorite ? Haptic.medium : Haptic.light);
          },
        );
      },
    );
  }

  Widget _buildDownloadButton() {
    return ListenableBuilder(
      listenable: DownloadStore.instance,
      builder: (context, _) {
        final store = DownloadStore.instance;
        final id = widget.video.id;
        final item = store.item(id);

        if (item == null) {
          return AppButton(
            label: 'Download',
            icon: Icons.download_rounded,
            style: AppButtonStyle.secondary,
            onDark: true,
            onPressed: () {
              store.enqueue(widget.video);
              showToast(context, 'Download started', aboveBar: false);
            },
          );
        }

        if (item.status == DownloadStatus.done) {
          return Wrap(
            spacing: Gaps.sm,
            runSpacing: Gaps.sm,
            children: [
              AppButton(
                label: 'Downloaded',
                icon: Icons.download_done_rounded,
                iconColor: const Color(0xFFB8AEFF),
                style: AppButtonStyle.secondary,
                onDark: true,
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Delete this download?',
                    message: 'The video will be removed from your phone.',
                    confirmLabel: 'Delete',
                  );
                  if (ok) await store.remove(id);
                },
              ),
              AppButton(
                label: 'Save to Photos',
                icon: Icons.photo_library_outlined,
                style: AppButtonStyle.secondary,
                onDark: true,
                onPressed: () => saveVideoToPhotos(context, id, aboveBar: false),
              ),
            ],
          );
        }

        return ValueListenableBuilder<int>(
          valueListenable: item.bytes,
          builder: (context, _, __) {
            final fraction = item.progress;
            final percent = fraction == null ? '' : ' ${(fraction * 100).round()}%';
            switch (item.status) {
              case DownloadStatus.downloading:
                return AppButton(
                  label: fraction == null ? 'Downloading\u2026' : '${(fraction * 100).round()}%',
                  icon: Icons.pause_rounded,
                  style: AppButtonStyle.secondary,
                  onDark: true,
                  onPressed: () => store.pause(id),
                );
              case DownloadStatus.queued:
                return AppButton(
                  label: 'Waiting\u2026',
                  icon: Icons.pause_rounded,
                  style: AppButtonStyle.secondary,
                  onDark: true,
                  onPressed: () => store.pause(id),
                );
              case DownloadStatus.paused:
              case DownloadStatus.failed:
              case DownloadStatus.done:
                return AppButton(
                  label: item.hasPartial ? 'Resume$percent' : 'Retry download',
                  icon: Icons.play_arrow_rounded,
                  style: AppButtonStyle.secondary,
                  onDark: true,
                  onPressed: () => store.resume(id),
                );
            }
          },
        );
      },
    );
  }

  double _headerHeight(Size size) => math.min(size.height * 0.5, 460.0);

  Widget _buildModels(double margin) {
    return FutureBuilder<List<ModelRef>>(
      future: _modelsFuture,
      builder: (context, snapshot) {
        final models = snapshot.data ?? const <ModelRef>[];
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError ||
            models.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(margin, Gaps.lg, margin, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                models.length == 1 ? 'Model' : 'Models',
                style: AppText.label.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: Gaps.sm),
              Wrap(
                spacing: Gaps.sm,
                runSpacing: Gaps.sm,
                children: [
                  for (final model in models)
                    _ModelChip(
                      name: model.name,
                      onPressed: () => _openModel(model),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRelatedTitle(double margin) {
    return FutureBuilder<List<Video>>(
      future: _relatedFuture,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
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

class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.name, required this.onPressed});

  final String name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: 'Model $name',
      haptic: Haptic.selection,
      pressedScale: 0.95,
      onTap: onPressed,
      child: Container(
        height: 36,
        padding: const EdgeInsets.only(left: 10, right: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_rounded, size: 18, color: AppColors.accent),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
