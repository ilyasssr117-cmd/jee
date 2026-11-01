import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
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
import 'widgets/dialogs.dart';
import 'widgets/expandable_text.dart';
import 'widgets/model_avatar.dart';
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
  static const Duration _detailsLoadLimit = Duration(seconds: 18);
  static const Duration _refreshIndicatorLimit = Duration(seconds: 8);
  late Future<List<Video>> _relatedFuture;
  late Future<List<ModelRef>> _modelsFuture;
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();

  final ValueNotifier<bool> _overHeader = ValueNotifier<bool>(true);

  double _headerLimit = 200;
  bool _preparing = false;
  bool _refreshing = false;
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

  Future<List<Video>> _loadRelated({
    bool force = false,
    bool fresh = false,
  }) =>
      relatedCache
          .fetch(
            widget.video.id,
            () => videoRepository.getRelated(
              widget.video,
              fresh: fresh,
            ),
            force: force,
          )
          .timeout(_detailsLoadLimit);

  Future<List<ModelRef>> _loadModels({
    bool force = false,
    bool fresh = false,
  }) =>
      modelsCache
          .fetch(
            widget.video.id,
            () => videoRepository.getVideoModels(
              widget.video,
              fresh: fresh,
            ),
            force: force,
          )
          .timeout(_detailsLoadLimit);

  void _openModel(ModelRef model) {
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(context, builder: (_) => ModelPage(model: model)),
    );
  }

  void _reloadRelated() {
    if (!mounted) return;
    setState(() => _relatedFuture = _loadRelated(force: true, fresh: true));
  }

  void _reloadModels() {
    if (!mounted) return;
    setState(() => _modelsFuture = _loadModels(force: true, fresh: true));
  }

  Future<void> _refreshDetails() async {
    if (_refreshing) return;
    Haptics.play(Haptic.light);
    _refreshing = true;

    // Start a genuinely fresh detail-page request. The model lookup joins that
    // request, while the two sections continue rendering independently.
    final related = _loadRelated(force: true, fresh: true);
    final models = _loadModels(force: true);
    if (mounted) {
      setState(() {
        _relatedFuture = related;
        _modelsFuture = models;
      });
    }

    var failed = false;
    var tookTooLong = false;

    Future<void> settle<T>(Future<T> task) async {
      try {
        await task;
      } catch (_) {
        failed = true;
      }
    }

    try {
      // The refresh indicator has its own shorter deadline. A slow connection
      // can keep updating the FutureBuilder sections, but cannot trap the user
      // under a spinner indefinitely.
      await Future.wait<void>(<Future<void>>[
        settle(related),
        settle(models),
      ]).timeout(
        _refreshIndicatorLimit,
        onTimeout: () {
          tookTooLong = true;
          return <void>[];
        },
      );
    } finally {
      _refreshing = false;
    }

    if (!mounted) return;
    if (failed) {
      showToast(
        context,
        'Couldn’t refresh. Check your connection and try again.',
      );
    } else if (tookTooLong) {
      showToast(
        context,
        'Refresh is taking longer. Results will update when ready.',
      );
    } else {
      Haptics.play(Haptic.selection);
    }
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
      adaptivePageRoute<void>(
        context,
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
    _headerLimit = _headerHeight(MediaQuery.sizeOf(context)) - context.safe.top;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final render = _headerKey.currentContext?.findRenderObject();
      if (render is RenderBox && render.hasSize) {
        final measured = render.size.height - context.safe.top;
        if ((measured - _headerLimit).abs() > 1) {
          _headerLimit = measured;
          final over = !_scroll.hasClients || _scroll.offset < _headerLimit;
          if (_overHeader.value != over) _overHeader.value = over;
        }
      }
    });
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    return ValueListenableBuilder<bool>(
      valueListenable: _overHeader,
      builder: (context, overHeader, child) =>
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: darkMode || overHeader
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            child: child!,
          ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: ColoredBox(
          color: AppColors.background,
          child: CustomScrollView(
            key: PageStorageKey<String>('video-details-${widget.video.id}'),
            controller: _scroll,
            physics: nativeScrollPhysics(context, alwaysScrollable: true),
            scrollCacheExtent: ScrollCacheExtent.pixels(
              MediaQuery.sizeOf(context).height,
            ),
            slivers: [
              CupertinoSliverRefreshControl(
                onRefresh: _refreshDetails,
                refreshTriggerPullDistance: 84,
                refreshIndicatorExtent: 52,
              ),
              SliverToBoxAdapter(child: _buildHeader(margin)),
              SliverToBoxAdapter(child: _buildRelatedTitle(margin)),
              _buildRelated(margin),
              SliverToBoxAdapter(
                child: SizedBox(height: Gaps.xl + context.safe.bottom),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    // Use a taller, full-bleed artwork area. The sharp image fills the frame
    // without distortion (BoxFit.cover preserves its ratio); the blurred copy
    // underneath is revealed softly along the sides and lower edge.
    final artworkHeight = MediaQuery.sizeOf(context).width * 0.74;
    final resume = PlaybackProgress.instance.resumePosition(video.id);

    final meta = VideoMetaLine(
      video: video,
      style: const TextStyle(
        color: Color(0xFFD6D9E2),
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
      ),
      showDuration: true,
      showDate: true,
      fallbackToCategory: false,
    );

    // The artwork is a fixed background layer. Details are laid over it,
    // restoring the original visual composition without a shared Hero route.
    return ConstrainedBox(
      key: _headerKey,
      constraints: BoxConstraints(
        minHeight: _headerHeight(MediaQuery.sizeOf(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: AppColors.surfaceHigh),
                    ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: 32,
                        sigmaY: 32,
                      ),
                      child: VideoArtwork(
                        video: video,
                        showLabel: false,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const ColoredBox(color: Color(0x35000000)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.0, 0.22, 0.52, 1.0],
                          colors: [
                            Color(0x50000000),
                            Color(0x10000000),
                            Color(0x70000000),
                            Color(0xE60B0D12),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: artworkHeight,
              child: ShaderMask(
                // Let the image occupy the whole artwork frame, then dissolve
                // its lower portion into the same image blurred underneath.
                // This avoids a hard rectangular edge before the title.
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black, Colors.black, Colors.transparent],
                  stops: [0.0, 0.68, 1.0],
                ).createShader(bounds),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ShaderMask(
                      // Keep most of the photo crisp and full-width. Only a
                      // narrow strip at each side reveals the blurred copy,
                      // creating a soft edge rather than a visible image frame.
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.transparent,
                          Colors.black,
                          Colors.black,
                          Colors.transparent,
                        ],
                        stops: [0.0, 0.10, 0.90, 1.0],
                      ).createShader(bounds),
                      child: VideoArtwork(
                        video: video,
                        showLabel: false,
                        fit: BoxFit.cover,
                        transparentBackground: true,
                      ),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x24000000),
                            Color(0x00000000),
                          ],
                          stops: [0, 0.48],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                margin,
                artworkHeight + Gaps.md,
                margin,
                Gaps.lg,
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
                      style: darkText.overline.copyWith(
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  const SizedBox(height: 6),
                  ExpandableText(
                    video.title,
                    collapsedLines: 3,
                    style: darkText.display.copyWith(
                      fontSize: 23,
                      color: Colors.white,
                      height: 1.12,
                      shadows: const [
                        Shadow(color: Color(0x66000000), blurRadius: 12),
                      ],
                    ),
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
                      style: const TextStyle(
                        color: Color(0xFFD6D9E2),
                        fontSize: 13,
                        height: 1.42,
                      ),
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
                          onDark: true,
                          onPressed: () => _play(fromStart: true),
                        ),
                      _buildFavoriteButton(),
                      _buildDownloadButton(),
                      if (_shareLink != null)
                        AppButton(
                          label: 'Copy link',
                          icon: Icons.link_rounded,
                          style: AppButtonStyle.secondary,
                          onDark: true,
                          onPressed: _copyLink,
                        ),
                    ],
                  ),
                  if (_playError != null) ...[
                    const SizedBox(height: Gaps.sm),
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 20,
                          color: Color(0xFFFF8A80),
                        ),
                        const SizedBox(width: Gaps.sm),
                        Flexible(
                          child: Text(
                            _playError!,
                            style: const TextStyle(
                              color: Color(0xFFFF8A80),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  _buildModels(onDark: true),
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

  String? get _shareLink {
    final uri = Uri.tryParse(widget.video.pageUrl?.trim() ?? '');
    final valid =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    return valid ? uri.toString() : null;
  }

  Future<void> _copyLink() async {
    final link = _shareLink;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    Haptics.play(Haptic.light);
    showToast(context, 'Link copied', aboveBar: false);
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
                iconColor: AppColors.accent,
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
                onPressed: () =>
                    saveVideoToPhotos(context, id, aboveBar: false),
              ),
            ],
          );
        }

        return ValueListenableBuilder<int>(
          valueListenable: item.bytes,
          builder: (context, _, __) {
            final fraction = item.progress;
            final percent = fraction == null
                ? ''
                : ' ${(fraction * 100).round()}%';
            switch (item.status) {
              case DownloadStatus.downloading:
                return AppButton(
                  label: fraction == null
                      ? 'Downloading\u2026'
                      : '${(fraction * 100).round()}%',
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

  double _headerHeight(Size size) => size.width * 0.66 + 84;

  Widget _buildModels({bool onDark = false}) {
    return FutureBuilder<List<ModelRef>>(
      future: _modelsFuture,
      builder: (context, snapshot) {
        final models = snapshot.data ?? const <ModelRef>[];
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: Gaps.lg),
            child: SizedBox(height: 2),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(top: Gaps.lg),
            child: Row(
              children: [
                Expanded(
                  child: Text('Couldn’t load model information.', style: AppText.body),
                ),
                AppButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  style: AppButtonStyle.secondary,
                  onDark: onDark,
                  onPressed: _reloadModels,
                ),
              ],
            ),
          );
        }
        if (models.isEmpty) return const SizedBox.shrink();
        final titleStyle = AppText.label.copyWith(
          color: onDark
              ? Colors.white.withValues(alpha: 0.78)
              : AppColors.textSecondary,
        );
        return Padding(
          padding: const EdgeInsets.only(top: Gaps.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                height: 1,
                margin: const EdgeInsets.only(bottom: Gaps.md),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.02),
                      Colors.white.withValues(alpha: 0.24),
                      Colors.white.withValues(alpha: 0.02),
                    ],
                  ),
                ),
              ),
              Text(
                models.length == 1 ? 'Model' : 'Models',
                style: titleStyle,
              ),
              const SizedBox(height: Gaps.sm),
              Wrap(
                spacing: Gaps.sm,
                runSpacing: Gaps.sm,
                children: [
                  for (final model in models)
                    _ModelChip(
                      name: model.name,
                      imageUrl: model.imageUrl,
                      pageUrl: model.url,
                      onDark: onDark,
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
        if (!waiting &&
            !snapshot.hasError &&
            (snapshot.data ?? const []).isEmpty) {
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
  const _ModelChip({
    required this.name,
    required this.imageUrl,
    required this.pageUrl,
    required this.onPressed,
    this.onDark = false,
  });

  final String name;
  final String? imageUrl;
  final String pageUrl;
  final VoidCallback onPressed;
  final bool onDark;

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
          color: onDark
              ? Colors.white.withValues(alpha: 0.14)
              : AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(
            color: onDark
                ? Colors.white.withValues(alpha: 0.24)
                : AppColors.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ModelAvatar(
              name: name,
              imageUrl: imageUrl,
              pageUrl: pageUrl,
              size: 25,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: onDark ? Colors.white : AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: onDark
                  ? Colors.white.withValues(alpha: 0.76)
                  : AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
