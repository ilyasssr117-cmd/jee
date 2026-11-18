import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'platform_ui.dart';
import 'analytics_service.dart';
import 'download_store.dart';
import 'favorites_store.dart';
import 'model_page.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'request_cache.dart';
import 'services/remote_config_service.dart';
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
import 'widgets/tv_controls.dart';
import 'widgets/bottom_bar.dart';

class VideoDetailsPage extends StatefulWidget {
  const VideoDetailsPage({
    super.key,
    required this.video,
    this.queue,
    this.onNavigate,
  });

  final Video video;

  final List<Video>? queue;
  final ValueChanged<AppTab>? onNavigate;

  @override
  State<VideoDetailsPage> createState() => _VideoDetailsPageState();
}

class _VideoDetailsPageState extends State<VideoDetailsPage> {
  static const Duration _detailsLoadLimit = Duration(seconds: 18);
  static const Duration _refreshIndicatorLimit = Duration(seconds: 8);
  late Future<List<Video>> _relatedFuture;
  late Future<List<ModelRef>> _modelsFuture;
  List<ModelRef> _models = const <ModelRef>[];
  Object? _modelsError;
  bool _modelsLoading = true;
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();

  final ValueNotifier<bool> _overHeader = ValueNotifier<bool>(true);

  double _headerLimit = 200;
  bool _preparing = false;
  bool _refreshing = false;
  final ValueNotifier<bool> _shareCopied = ValueNotifier<bool>(false);
  Timer? _shareResetTimer;
  String? _playError;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.trackVideoDetailsOpen(widget.video.id);
    _relatedFuture = _loadRelated();
    _modelsFuture = _loadModels();
    _watchModels(_modelsFuture);
    _scroll.addListener(() {
      final over = !_scroll.hasClients || _scroll.offset < _headerLimit;
      if (over != _overHeader.value) _overHeader.value = over;
    });
  }

  @override
  void dispose() {
    _shareResetTimer?.cancel();
    _shareCopied.dispose();
    _scroll.dispose();
    _overHeader.dispose();
    super.dispose();
  }

  String get _sourceScopedVideoKey {
    final pageUrl = widget.video.pageUrl;
    final host = pageUrl == null
        ? null
        : Uri.tryParse(pageUrl)?.host.toLowerCase();
    final source = host == null || host.isEmpty
        ? videoRepository.source.name
        : host;
    return '$source|${widget.video.id}';
  }

  Future<List<Video>> _loadRelated({
    bool force = false,
    bool fresh = false,
  }) =>
      relatedCache
          .fetch(
            'related|$_sourceScopedVideoKey',
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
            'models|$_sourceScopedVideoKey',
            () => videoRepository.getVideoModels(
              widget.video,
              fresh: fresh,
            ),
            force: force,
          )
          .timeout(_detailsLoadLimit);

  void _watchModels(Future<List<ModelRef>> request) {
    request.then<void>(
      (models) {
        if (!mounted || !identical(request, _modelsFuture)) return;
        setState(() {
          if (models.isNotEmpty || _models.isEmpty) {
            _models = models;
          }
          _modelsError = null;
          _modelsLoading = false;
        });
      },
      onError: (Object error) {
        if (!mounted || !identical(request, _modelsFuture)) return;
        if (_models.isNotEmpty) return;
        setState(() {
          _modelsError = error;
          _modelsLoading = false;
        });
      },
    );
  }

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
    final request = _loadModels(force: true, fresh: true);
    setState(() {
      _modelsFuture = request;
      _modelsError = null;
      _modelsLoading = true;
    });
    _watchModels(request);
  }

  Future<void> _refreshDetails() async {
    if (_refreshing) return;
    Haptics.play(Haptic.light);
    _refreshing = true;

    final related = _loadRelated(force: true, fresh: true);
    if (mounted) {
      setState(() {
        _relatedFuture = related;
      });
    }

    var failed = false;
    var tookTooLong = false;

    Future<void> settleRelated() async {
      try {
        await related;
      } catch (_) {
        failed = true;
      }
    }

    try {
      await settleRelated().timeout(
        _refreshIndicatorLimit,
        onTimeout: () {
          tookTooLong = true;
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
        builder: (_) => VideoDetailsPage(
          video: video,
          queue: related,
          onNavigate: widget.onNavigate,
        ),
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

  void _navigateFromTv(AppTab tab) {
    final callback = widget.onNavigate;
    Navigator.of(context).pop();
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback(tab));
    }
  }

  void _showTvInfo() {
    final video = widget.video;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF171B25),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(video.title, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                Text(
                  video.description.isNotEmpty ? video.description : 'No description is available for this video.',
                  style: const TextStyle(color: Color(0xFFD0D5DF), fontSize: 17, height: 1.5),
                ),
                const SizedBox(height: 18),
                Text(
                  <String>[
                    if (video.duration.isNotEmpty) video.duration,
                    if (video.views.isNotEmpty) '${video.views} views',
                    if (video.date.isNotEmpty) video.date,
                  ].join('   •   '),
                  style: const TextStyle(color: Color(0xFF9FA9B9), fontSize: 14),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: TvFocusSurface(
                    autofocus: true,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    minWidth: 120,
                    minHeight: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                    child: const Center(child: Text('Close', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTvDetails() {
    final video = widget.video;
    final resume = PlaybackProgress.instance.resumePosition(video.id);
    final isFavorite = FavoritesStore.instance.isFavorite(video.id);

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.contextMenu) {
          if (event is KeyDownEvent) _showTvInfo();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.browserFavorites &&
            RemoteConfigService.instance.isFeatureEnabled('favorites')) {
          if (event is KeyDownEvent) {
            final added = FavoritesStore.instance.toggle(video);
            setState(() {});
            showToast(context, added ? 'Added to Watchlist' : 'Removed from Watchlist');
          }
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.channelUp ||
              event.logicalKey == LogicalKeyboardKey.pageDown) {
            _stepTvQueue(next: true);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.channelDown ||
              event.logicalKey == LogicalKeyboardKey.pageUp) {
            _stepTvQueue(next: false);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF080A0F),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            left: widget.onNavigate == null ? 0 : 102,
            child: VideoArtwork(video: video, fit: BoxFit.cover, showLabel: false),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    const Color(0xFF080A0F).withValues(alpha: 1),
                    const Color(0xFF080A0F).withValues(alpha: 0.96),
                    const Color(0xFF080A0F).withValues(alpha: 0.78),
                    const Color(0xFF080A0F).withValues(alpha: 0.35),
                    const Color(0xFF080A0F).withValues(alpha: 0.22),
                  ],
                  stops: const <double>[0, 0.30, 0.57, 0.82, 1],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: <Color>[const Color(0xFF080A0F), Colors.transparent],
                  stops: const <double>[0, 0.54],
                ),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              if (widget.onNavigate != null)
                TvNavigationRail(
                  selected: AppTab.values.indexOf(AppTab.home),
                  isEnabled: (index) {
                    if (index == AppTab.search.index) {
                      return RemoteConfigService.instance.isFeatureEnabled('search');
                    }
                    if (index == AppTab.reels.index) {
                      return RemoteConfigService.instance.isFeatureEnabled('reels');
                    }
                    return true;
                  },
                  onSelect: (index) => _navigateFromTv(AppTab.values[index]),
                )
              else
                const SizedBox(width: 28),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(42, 24, 34, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Text.rich(
                            TextSpan(children: <InlineSpan>[
                              TextSpan(text: 'VX', style: TextStyle(color: Colors.white)),
                              TextSpan(text: 'TUBE', style: TextStyle(color: Color(0xFF70A8FF))),
                            ]),
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.8),
                          ),
                          const Spacer(),
                          const Text('VIDEO DETAILS', style: TextStyle(color: Color(0xFFB8C0D0), fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                        ],
                      ),
                      Expanded(
                        flex: 5,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 800),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  video.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 42, height: 1.08, fontWeight: FontWeight.w900, letterSpacing: -1.1),
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 18,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: <Widget>[
                                    if (video.duration.isNotEmpty) _tvMetaChip(video.duration),
                                    if (video.views.isNotEmpty) _tvMetaChip('${video.views} views', icon: Icons.visibility_outlined),
                                    if (video.date.isNotEmpty) _tvMetaChip(video.date),
                                    _tvMetaChip(video.category),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  video.description.isNotEmpty ? video.description : 'Watch this video on VXTUBE.',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Color(0xFFD0D5DF), fontSize: 17, height: 1.45),
                                ),
                                const SizedBox(height: 24),
                                Wrap(
                                  spacing: 14,
                                  runSpacing: 12,
                                  children: <Widget>[
                                    TvFocusSurface(
                                      autofocus: true,
                                      onPressed: _preparing ? () {} : _play,
                                      backgroundColor: const Color(0xFF174B9A),
                                      focusedColor: const Color(0xFF2566C7),
                                      minWidth: 176,
                                      minHeight: 58,
                                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          Icon(_preparing ? Icons.hourglass_top_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 27),
                                          const SizedBox(width: 10),
                                          Text(_preparing ? 'Starting…' : (resume != null ? 'Resume' : 'Play'), style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                                        ],
                                      ),
                                    ),
                                    if (RemoteConfigService.instance.isFeatureEnabled('favorites'))
                                      TvFocusSurface(
                                        onPressed: () {
                                          final added = FavoritesStore.instance.toggle(video);
                                          setState(() {});
                                          showToast(context, added ? 'Added to Watchlist' : 'Removed from Watchlist');
                                        },
                                        minWidth: 205,
                                        minHeight: 58,
                                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(isFavorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, color: Colors.white, size: 23),
                                            const SizedBox(width: 9),
                                            Text(isFavorite ? 'In Watchlist' : 'Watchlist', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                                          ],
                                        ),
                                      ),
                                    TvFocusSurface(
                                      onPressed: _showTvInfo,
                                      minWidth: 140,
                                      minHeight: 58,
                                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          Icon(Icons.info_outline_rounded, color: Colors.white, size: 23),
                                          SizedBox(width: 8),
                                          Text('Info', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (_playError != null) ...<Widget>[
                                  const SizedBox(height: 12),
                                  Text(_playError!, style: const TextStyle(color: Color(0xFFFF9A9A), fontSize: 14)),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text('Related videos', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 184,
                        child: FutureBuilder<List<Video>>(
                          future: _relatedFuture,
                          builder: (context, snapshot) {
                            final items = snapshot.data ?? widget.queue ?? const <Video>[];
                            if (snapshot.connectionState != ConnectionState.done && items.isEmpty) {
                              return const Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator(color: Color(0xFF80AEFF), strokeWidth: 2.5));
                            }
                            if (snapshot.hasError && items.isEmpty) {
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: TvFocusSurface(
                                  onPressed: _reloadRelated,
                                  child: const Text('Retry related videos', style: TextStyle(color: Colors.white, fontSize: 15)),
                                ),
                              );
                            }
                            final related = items.where((item) => item.id != video.id).toList();
                            if (related.isEmpty) {
                              return const Align(alignment: Alignment.centerLeft, child: Text('No related videos found.', style: TextStyle(color: Color(0xFFABB2C0), fontSize: 15)));
                            }
                            return ListView.separated(
                              scrollDirection: Axis.horizontal,
                              clipBehavior: Clip.none,
                              itemCount: related.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 13),
                              itemBuilder: (context, index) => TvVideoCard(
                                video: related[index],
                                width: 222,
                                onPressed: () => _openRelated(related[index], related),
                                onBookmark: RemoteConfigService.instance.isFeatureEnabled('favorites')
                                    ? () {
                                        final added = FavoritesStore.instance.toggle(related[index]);
                                        showToast(context, added ? 'Added to Watchlist' : 'Removed from Watchlist');
                                      }
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  void _stepTvQueue({required bool next}) {
    final queue = widget.queue ?? const <Video>[];
    final currentIndex = queue.indexWhere((item) => item.id == widget.video.id);
    if (currentIndex < 0) return;
    final targetIndex = currentIndex + (next ? 1 : -1);
    if (targetIndex < 0 || targetIndex >= queue.length) return;
    _openRelated(queue[targetIndex], queue);
  }

  Widget _tvMetaChip(String label, {IconData? icon}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, color: const Color(0xFFD0D5DF), size: 16),
          const SizedBox(width: 6),
        ],
        Text(label, style: const TextStyle(color: Color(0xFFD0D5DF), fontSize: 15, fontWeight: FontWeight.w600)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isAndroidTv) return _buildTvDetails();
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
          child: RefreshIndicator(
            onRefresh: _refreshDetails,
            color: AppColors.accentForeground,
            backgroundColor: AppColors.surface,
            edgeOffset: context.safe.top + Gaps.sm,
            displacement: 44,
            child: CustomScrollView(
              key: PageStorageKey<String>('video-details-${widget.video.id}'),
              controller: _scroll,
              physics: nativeScrollPhysics(context, alwaysScrollable: true),
              scrollCacheExtent: ScrollCacheExtent.pixels(
                MediaQuery.sizeOf(context).height * 0.7,
              ),
              slivers: [
                SliverToBoxAdapter(
                  child: _DetailsHeroStretch(
                    controller: _scroll,
                    child: _buildHeader(margin),
                  ),
                ),
                if (_models.isNotEmpty ||
                    _modelsError != null ||
                    _modelsLoading)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _PinnedModelsDelegate(
                      extent: _modelsHeaderExtent(context),
                      margin: margin,
                      models: _models,
                      loading: _modelsLoading,
                      error: _modelsError,
                      onRetry: _reloadModels,
                      onOpen: _openModel,
                    ),
                  ),
                SliverToBoxAdapter(child: _buildRelatedTitle(margin)),
                _buildRelated(margin),
                SliverToBoxAdapter(
                  child: SizedBox(height: Gaps.xl + context.safe.bottom),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(double margin) {
    final video = widget.video;
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
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

    return ConstrainedBox(
      key: _headerKey,
      constraints: BoxConstraints(
        minHeight: _headerHeight(MediaQuery.sizeOf(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(windowsDesktop ? 0 : 28),
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (windowsDesktop) ...[
                      VideoArtwork(
                        video: video,
                        showLabel: false,
                        fit: BoxFit.cover,
                      ),
                      const ColoredBox(color: Color(0x66000000)),
                    ] else ...[
                      ColoredBox(color: AppColors.surfaceHigh),
                      ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 30,
                          sigmaY: 30,
                        ),
                        child: VideoArtwork(
                          video: video,
                          showLabel: false,
                          fit: BoxFit.cover,
                        ),
                      ),
                      ShaderMask(
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
                          stops: [0.0, 0.075, 0.925, 1.0],
                        ).createShader(bounds),
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black,
                              Colors.black,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.44, 1.0],
                          ).createShader(bounds),
                          child: VideoArtwork(
                            video: video,
                            showLabel: false,
                            fit: BoxFit.cover,
                            transparentBackground: true,
                          ),
                        ),
                      ),
                    ],
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.0, 0.30, 0.64, 1.0],
                          colors: [
                            Color(0x300C1020),
                            Color(0x180C1020),
                            Color(0x650C1020),
                            Color(0xE80C1020),
                          ],
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
                context.safe.top + Gaps.sm + kMinTapSize + Gaps.md,
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
                    collapsedLines: 2,
                    style: darkText.display.copyWith(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFD6D9E2),
                        fontSize: 13,
                        height: 1.42,
                      ),
                    ),
                  ],
                  const SizedBox(height: Gaps.md),
                  _buildHeaderActions(resume),
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
    final valid = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    return valid ? uri.toString() : null;
  }

  Future<void> _copyLink() async {
    final link = _shareLink;
    if (link == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: link));
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (!mounted) return;
    Haptics.play(Haptic.light);
    _shareResetTimer?.cancel();
    _shareCopied.value = true;
    _shareResetTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) _shareCopied.value = false;
    });
  }

  Widget _buildHeaderActions(Duration? resume) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionCount = _shareLink == null ? 2 : 3;
        final actionGaps = Gaps.xs * (actionCount - 1);
        final actionWidth = (constraints.maxWidth - actionGaps) / actionCount;
        final requiredLabelWidth = math.max(
          appButtonRequiredWidth(context, label: 'Favorited'),
          appButtonRequiredWidth(context, label: 'Download'),
        );
        final compact = actionWidth < requiredLabelWidth;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: resume == null
                        ? 'Play'
                        : 'Resume ${_formatResume(resume)}',
                    icon: Icons.play_arrow_rounded,
                    loading: _preparing,
                    expand: true,
                    onPressed: _play,
                  ),
                ),
                if (resume != null) ...[
                  const SizedBox(width: Gaps.sm),
                  Expanded(
                    child: AppButton(
                      label: 'Start over',
                      icon: Icons.replay_rounded,
                      style: AppButtonStyle.secondary,
                      onDark: true,
                      expand: true,
                      onPressed: () => _play(fromStart: true),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Gaps.sm),
            Row(
              children: [
                Expanded(child: _buildFavoriteButton(compact: compact)),
                const SizedBox(width: Gaps.xs),
                Expanded(child: _buildDownloadButton(compact: compact)),
                if (_shareLink != null) ...[
                  const SizedBox(width: Gaps.xs),
                  Expanded(child: _buildShareButton(compact: compact)),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildShareButton({required bool compact}) {
    return ValueListenableBuilder<bool>(
      valueListenable: _shareCopied,
      builder: (context, copied, _) => Semantics(
        button: true,
        label: copied ? 'Video link copied' : 'Copy video link',
        child: SizedBox(
          height: 46,
          width: double.infinity,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _copyLink,
              borderRadius: BorderRadius.circular(Radii.button),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 22,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      reverseDuration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) =>
                          RotationTransition(
                        turns: Tween<double>(begin: -0.12, end: 0)
                            .animate(animation),
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: copied
                          ? const Icon(
                              Icons.check_rounded,
                              key: ValueKey<String>('copied'),
                              size: 20,
                              color: Color(0xFF63D98B),
                            )
                          : const Icon(
                              Icons.ios_share_rounded,
                              key: ValueKey<String>('share'),
                              size: 20,
                              color: Colors.white,
                            ),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    Text(
                      'Share',
                      maxLines: 1,
                      softWrap: false,
                      style: AppText.label.copyWith(color: Colors.white),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteButton({required bool compact}) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        FavoritesStore.instance,
        RemoteConfigService.instance,
      ]),
      builder: (context, _) {
        final active = FavoritesStore.instance.isFavorite(widget.video.id);
        return AppButton(
          label: compact ? '' : (active ? 'Favorited' : 'Favorite'),
          semanticLabel: active ? 'Favorited' : 'Favorite',
          icon: active ? Icons.star_rounded : Icons.star_border_rounded,
          iconColor: active ? AppColors.star : null,
          style: AppButtonStyle.tertiary,
          onDark: true,
          expand: true,
          singleLine: true,
          onPressed: () {
            if (!RemoteConfigService.instance.isFeatureEnabled('favorites')) {
              return;
            }
            final nowFavorite = FavoritesStore.instance.toggle(widget.video);
            Haptics.play(nowFavorite ? Haptic.medium : Haptic.light);
          },
        );
      },
    );
  }

  Widget _buildDownloadButton({required bool compact}) {
    return ListenableBuilder(
      listenable: DownloadStore.instance,
      builder: (context, _) {
        final store = DownloadStore.instance;
        final id = widget.video.id;
        final item = store.item(id);

        if (item == null) {
          return AppButton(
            label: compact ? '' : 'Download',
            semanticLabel: 'Download',
            icon: Icons.download_rounded,
            style: AppButtonStyle.tertiary,
            onDark: true,
            expand: true,
            singleLine: true,
            onPressed: () {
              store.enqueue(widget.video);
              showToast(context, 'Download started', aboveBar: false);
            },
          );
        }

        if (item.status == DownloadStatus.done) {
          return PopupMenuButton<String>(
            tooltip: 'Download options',
            onSelected: (action) async {
              if (action == 'photos') {
                await saveVideoToPhotos(context, id, aboveBar: false);
              } else if (action == 'delete') {
                final ok = await confirmDialog(
                  context,
                  title: 'Delete this download?',
                  message: 'The video will be removed from your phone.',
                  confirmLabel: 'Delete',
                );
                if (ok) await store.remove(id);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'photos',
                child: Text('Save to Photos'),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Text('Delete download'),
              ),
            ],
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: AppButton(
                  label: compact ? '' : 'Saved',
                  semanticLabel: 'Download options',
                  icon: Icons.download_done_rounded,
                  iconColor: AppColors.accent,
                  style: AppButtonStyle.tertiary,
                  onDark: true,
                  expand: true,
                  singleLine: true,
                  onPressed: () {},
                ),
              ),
            ),
          );
        }

        return ValueListenableBuilder<int>(
          valueListenable: item.bytes,
          builder: (context, _, __) {
            final fraction = item.progress;
            final percent =
                fraction == null ? '' : ' ${(fraction * 100).round()}%';
            switch (item.status) {
              case DownloadStatus.downloading:
                return AppButton(
                  label: fraction == null ? '' : '${(fraction * 100).round()}%',
                  semanticLabel: fraction == null
                      ? 'Downloading'
                      : 'Downloading ${(fraction * 100).round()} percent',
                  icon: Icons.pause_rounded,
                  style: AppButtonStyle.tertiary,
                  onDark: true,
                  expand: true,
                  singleLine: true,
                  onPressed: () => store.pause(id),
                );
              case DownloadStatus.queued:
                return AppButton(
                  label: compact ? '' : 'Waiting',
                  semanticLabel: 'Download waiting',
                  icon: Icons.pause_rounded,
                  style: AppButtonStyle.tertiary,
                  onDark: true,
                  expand: true,
                  singleLine: true,
                  onPressed: () => store.pause(id),
                );
              case DownloadStatus.paused:
              case DownloadStatus.failed:
              case DownloadStatus.done:
                return AppButton(
                  label: compact
                      ? (fraction == null ? '' : '${(fraction * 100).round()}%')
                      : (item.hasPartial ? 'Resume' : 'Retry'),
                  semanticLabel: item.hasPartial
                      ? 'Resume download$percent'
                      : 'Retry download',
                  icon: Icons.play_arrow_rounded,
                  style: AppButtonStyle.tertiary,
                  onDark: true,
                  expand: true,
                  singleLine: true,
                  onPressed: () => store.resume(id),
                );
            }
          },
        );
      },
    );
  }

  double _headerHeight(Size size) =>
      (size.width * 0.58 + 112).clamp(320.0, 400.0).toDouble();

  double _modelsHeaderExtent(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final chipHeight = math.max(36.0, 28 * scale + 8);
    final labelHeight = 13 * scale * 1.2;
    final safePinned = context.safe.top + chipHeight + 10;
    final unpinned = labelHeight + 5 + chipHeight + 14;
    return math.max(78.0, math.max(safePinned, unpinned));
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

class _DetailsHeroStretch extends StatelessWidget {
  const _DetailsHeroStretch({
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final pulled = controller.hasClients
            ? (-controller.position.pixels).clamp(0.0, 120.0).toDouble()
            : 0.0;
        final scale = 1.0 + pulled / 2400.0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (pulled > 0)
              const Positioned(
                left: 0,
                right: 0,
                top: -400,
                height: 440,
                child: ColoredBox(color: Color(0xFF0C1020)),
              ),
            Transform.scale(
              scale: scale,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ],
        );
      },
    );
  }
}

class _PinnedModelsDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedModelsDelegate({
    required this.extent,
    required this.margin,
    required this.models,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onOpen,
  });

  final double extent;
  final double margin;
  final List<ModelRef> models;
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;
  final ValueChanged<ModelRef> onOpen;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final pinned = shrinkOffset > 0 || overlapsContent;
    final topInset = pinned ? MediaQuery.paddingOf(context).top : 0.0;
    final hasModels = models.isNotEmpty;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final chipHeight = math.max(36.0, 28 * textScale + 8);

    return Material(
      color: AppColors.background,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: AppColors.outline.withValues(alpha: 0.55),
              width: 0.7,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            margin,
            pinned ? topInset : 7,
            margin,
            pinned ? 5 : 7,
          ),
          child: hasModels
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!pinned) ...[
                      Text(
                        models.length == 1 ? 'MODEL' : 'MODELS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label.copyWith(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 5),
                    ],
                    SizedBox(
                      height: chipHeight,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: models.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: Gaps.sm),
                        itemBuilder: (context, index) {
                          final model = models[index];
                          return _ModelChip(
                            key: ValueKey<String>('${model.url}|${model.name}'),
                            name: model.name,
                            imageUrl: model.imageUrl,
                            pageUrl: model.url,
                            onPressed: () => onOpen(model),
                          );
                        },
                      ),
                    ),
                  ],
                )
              : loading
                  ? Row(
                      children: [
                        Text(
                          'MODELS',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.label.copyWith(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            letterSpacing: 0.7,
                          ),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: math.min(22, chipHeight * 0.45),
                          height: math.min(22, chipHeight * 0.45),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accentForeground,
                          ),
                        ),
                      ],
                    )
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Couldn’t load model information.',
                              style: AppText.body,
                            ),
                          ),
                          AppButton(
                            label: 'Retry',
                            icon: Icons.refresh_rounded,
                            style: AppButtonStyle.secondary,
                            onPressed: onRetry,
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedModelsDelegate oldDelegate) =>
      extent != oldDelegate.extent ||
      margin != oldDelegate.margin ||
      !identical(models, oldDelegate.models) ||
      loading != oldDelegate.loading ||
      error != oldDelegate.error;
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.pageUrl,
    required this.onPressed,
  });

  final String name;
  final String? imageUrl;
  final String pageUrl;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final chipHeight = math.max(36.0, 28 * textScale + 8);
    final avatarSize = math.min(40.0, 25 * textScale);
    return Pressable(
      semanticLabel: 'Model $name',
      haptic: Haptic.selection,
      pressedScale: 0.95,
      onTap: onPressed,
      child: Container(
        height: chipHeight,
        padding: const EdgeInsets.only(left: 10, right: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(
            color: AppColors.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ModelAvatar(
              name: name,
              imageUrl: imageUrl,
              pageUrl: pageUrl,
              size: avatarSize,
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
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
