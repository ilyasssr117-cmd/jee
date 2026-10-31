import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'reels_page.dart';
import 'request_cache.dart';
import 'touch.dart';
import 'preview_manager.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/category_bar.dart';
import 'widgets/continue_row.dart';
import 'widgets/dialogs.dart';
import 'widgets/home_hero.dart';
import 'widgets/library_view.dart';
import 'widgets/search_overlay.dart';
import 'widgets/settings_view.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

enum _Section { home, library, settings }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const List<_Section> _sectionOrder = <_Section>[
    _Section.home,
    _Section.library,
    _Section.settings,
  ];

  static const int _pageSize = 12;

  static const int _maxEmptyPages = 3;

  static const String _hintsKey = 'hints_v1';

  final ScrollController _scroll = ScrollController();

  final List<Video> _videos = <Video>[];
  Video? _featured;
  List<Video> _gridVideos = const <Video>[];

  int _page = 0;
  int _generation = 0;
  int _emptyPages = 0;
  String _category = 'All';
  bool _loading = false;
  bool _hasMore = true;
  bool _playingFeatured = false;
  final ValueNotifier<bool> _search = ValueNotifier<bool>(false);
  bool get _searchOpen => _search.value;
  _Section _section = _Section.home;
  Widget? _libraryPage;
  Widget? _settingsPage;
  FriendlyError? _error;

  double _dragOffset = 0;
  _Section? _dragTarget;
  final Map<_Section, GlobalKey> _sectionHostKeys = <_Section, GlobalKey>{
    for (final section in _sectionOrder) section: GlobalKey(),
  };
  late final AnimationController _pageSettleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<double>? _pageSettleAnimation;

  List<String> get _categories => <String>['All', ...videoRepository.categories];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _pageSettleController.addListener(() {
      final animation = _pageSettleAnimation;
      if (!mounted || animation == null) return;
      setState(() => _dragOffset = animation.value);
    });
    _loadPage(reset: true);
  }

  Timer? _offlineTimer;
  ({LibrarySegment segment, int token})? _libraryRequest;
  int _requestToken = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_probeConnection());
  }

  void _watchConnection() {
    _offlineTimer?.cancel();
    _offlineTimer = Timer(const Duration(seconds: 15), _probeConnection);
  }

  Future<void> _probeConnection() async {
    if (!mounted || _loading || _videos.isNotEmpty) return;
    if (_error?.offline != true) return;
    final category = _category;
    try {
      await listingCache.fetch(
        'home|$category|0',
        () => videoRepository.getVideos(
          page: 0,
          pageSize: _pageSize,
          category: category == 'All' ? null : category,
        ),
      );
      if (!mounted || category != _category || _videos.isNotEmpty) return;
      unawaited(_loadPage(reset: true));
    } catch (_) {
      if (mounted) _watchConnection();
    }
  }

  void _showDownloads() {
    _libraryRequest = (
      segment: LibrarySegment.downloads,
      token: ++_requestToken,
    );
    _transitionToSection(_Section.library);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offlineTimer?.cancel();
    _pageSettleController.dispose();
    _search.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  bool _heroVisible = true;
  double _heroLimit = 200;

  void _onScroll() {
    _maybeLoadMore();
    final visible = !_scroll.hasClients || _scroll.offset < _heroLimit;
    if (visible != _heroVisible) setState(() => _heroVisible = visible);
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 800) _loadPage();
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || !_hasMore || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent < 100) _loadPage();
    });
  }

  void _recomputeDerived() {
    _featured = _videos.isNotEmpty ? _videos.first : null;
    _gridVideos = _videos.length > 1
        ? List<Video>.unmodifiable(_videos.skip(1))
        : const <Video>[];
  }

  void _applyPage(List<Video> result, int requestedPage) {
    final seenIds = _videos.map((video) => video.id).toSet();
    final fresh = <Video>[];
    for (final video in result) {
      if (seenIds.add(video.id)) fresh.add(video);
    }
    _videos.addAll(fresh);
    _recomputeDerived();
    _page = requestedPage + 1;
    _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
    _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
    _loading = false;
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading && !reset) return;
    final requestGeneration = reset ? ++_generation : _generation;
    final requestedPage = reset ? 0 : _page;
    final key = 'home|$_category|$requestedPage';

    final cached = listingCache.peek(key);
    if (cached != null) {
      setState(() {
        _error = null;
        if (reset) {
          _videos.clear();
          _page = 0;
          _emptyPages = 0;
        }
        _applyPage(cached, requestedPage);
      });
      if (_hasMore) _scheduleFillViewport();
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _videos.clear();
        _recomputeDerived();
        _page = 0;
        _emptyPages = 0;
        _hasMore = true;
      }
    });

    try {
      final result = await listingCache.fetch(
        key,
        () => videoRepository.getVideos(
          page: requestedPage,
          pageSize: _pageSize,
          category: _category == 'All' ? null : _category,
        ),
      );
      if (!mounted || requestGeneration != _generation) return;

      setState(() => _applyPage(result, requestedPage));
      if (_hasMore) _scheduleFillViewport();
      _maybeShowPreviewHint();
    } catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      setState(() {
        _loading = false;
        _hasMore = false;
        _error = describeError(error);
      });
      if (_error?.offline == true && _videos.isEmpty) _watchConnection();
    }
  }

  Future<void> _refresh() async {
    Haptics.play(Haptic.light);
    final generation = ++_generation;
    try {
      final result = await listingCache.fetch(
        'home|$_category|0',
        () => videoRepository.getVideos(
          page: 0,
          pageSize: _pageSize,
          category: _category == 'All' ? null : _category,
        ),
        force: true,
      );
      if (!mounted || generation != _generation) return;
      final seen = <String>{};
      final fresh = <Video>[
        for (final video in result)
          if (seen.add(video.id)) video,
      ];
      setState(() {
        _videos
          ..clear()
          ..addAll(fresh);
        _recomputeDerived();
        _page = 1;
        _emptyPages = 0;
        _hasMore = result.isNotEmpty;
        _loading = false;
        _error = null;
      });
      if (_hasMore) _scheduleFillViewport();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _loading = false);
      _toast('Couldn\u2019t refresh. Check your connection.');
    }
  }

  void _maybeShowPreviewHint() {
    if (_videos.isEmpty) return;
    final shown = LocalStore.readList(_hintsKey);
    if (shown.contains('preview')) return;
    LocalStore.writeList(_hintsKey, <String>[...shown, 'preview']);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast('Tip: press and hold a video to preview it');
    });
  }

  void _scrollToTop() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    _scroll.animateTo(0, duration: Motion.scroll, curve: Motion.curve);
  }

  void _toast(String message) => showToast(context, message);

  void _handleBack() {
    if (_searchOpen) {
      _closeSearch();
    } else if (_section != _Section.home) {
      PreviewManager.instance.stopNow(fade: false);
      _transitionToSection(_Section.home);
    }
  }

  void _openSearch() {
    if (_searchOpen) return;
    PreviewManager.instance.stopNow(fade: false);
    _search.value = true;
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _search.value = false;
  }

  Future<void> _openDetails(Video video, List<Video> queue) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: queue),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  _Section? _targetForDrag(double physicalDelta) {
    if (physicalDelta.abs() < 0.5) return null;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final forward = (physicalDelta < 0) != rtl;
    final next = _sectionOrder.indexOf(_section) + (forward ? 1 : -1);
    if (next < 0 || next >= _sectionOrder.length) return null;
    return _sectionOrder[next];
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_searchOpen) return;
    _pageSettleController.stop();
    setState(() {
      _dragOffset = 0;
      _dragTarget = null;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_searchOpen) return;
    final width = MediaQuery.sizeOf(context).width;
    final nextOffset = (_dragOffset + (details.primaryDelta ?? 0))
        .clamp(-width, width)
        .toDouble();
    final nextTarget = _targetForDrag(nextOffset);
    if (nextTarget != _dragTarget && nextTarget != null) {
      Haptics.play(Haptic.selection);
    }
    setState(() {
      _dragOffset = nextTarget == null ? nextOffset * 0.2 : nextOffset;
      _dragTarget = nextTarget;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_searchOpen) return;
    final width = MediaQuery.sizeOf(context).width;
    final velocity = details.velocity.pixelsPerSecond.dx;
    var target = _dragTarget;

    if (target == null && velocity.abs() > 650) {
      final physicalDirection = velocity.isNegative ? -1.0 : 1.0;
      target = _targetForDrag(physicalDirection);
      if (target != null) {
        setState(() {
          _dragOffset = physicalDirection * width * 0.08;
          _dragTarget = target;
        });
      }
    }

    final shouldCommit = target != null &&
        (_dragOffset.abs() > width * 0.22 || velocity.abs() > 650);
    _settlePageDrag(shouldCommit ? target : null);
  }

  void _onHorizontalDragCancel() => _settlePageDrag(null);

  void _settlePageDrag(_Section? destination) {
    final width = MediaQuery.sizeOf(context).width;
    final start = _dragOffset;
    final end = destination == null
        ? 0.0
        : (start < 0 ? -width : width);
    _pageSettleController
      ..stop()
      ..duration = Duration(
        milliseconds: (150 + (end - start).abs() / width * 100)
            .round()
            .clamp(150, 260)
            .toInt(),
      );
    _pageSettleAnimation = Tween<double>(begin: start, end: end).animate(
      CurvedAnimation(
        parent: _pageSettleController,
        curve: Curves.easeOutCubic,
      ),
    );
    _pageSettleController.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {
        if (destination != null) _section = destination;
        _dragOffset = 0;
        _dragTarget = null;
      });
      if (destination != null) Haptics.play(Haptic.medium);
    });
  }


  void _transitionToSection(_Section destination) {
    if (destination == _section) return;
    final width = MediaQuery.sizeOf(context).width;
    final currentIndex = _sectionOrder.indexOf(_section);
    final destinationIndex = _sectionOrder.indexOf(destination);
    final forward = destinationIndex > currentIndex;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final physicalDirection = (forward != rtl) ? -1.0 : 1.0;

    _pageSettleController.stop();
    setState(() {
      _dragOffset = physicalDirection * width * 0.06;
      _dragTarget = destination;
    });
    _settlePageDrag(destination);
  }

  void _onTabSelect(AppTab tab) {
    PreviewManager.instance.stopNow(fade: false);
    switch (tab) {
      case AppTab.home:
        if (_searchOpen) _closeSearch();
        if (_section == _Section.home) {
          _scrollToTop();
        } else {
          _transitionToSection(_Section.home);
        }
      case AppTab.search:
        _openSearch();
      case AppTab.reels:
        if (_searchOpen) _closeSearch();
        Navigator.of(context).push<void>(
          CupertinoPageRoute<void>(builder: (_) => const ReelsPage()),
        );
      case AppTab.library:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.library) {
          _transitionToSection(_Section.library);
        }
      case AppTab.settings:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.settings) {
          _transitionToSection(_Section.settings);
        }
    }
  }

  Future<void> _resume(Video video) async {
    final error = await launchPlayer(
      context,
      video,
      startAt: PlaybackProgress.instance.resumePosition(video.id),
    );
    if (!mounted) return;
    setState(() {});
    if (error != null) _toast(error);
  }

  Future<void> _playFeatured() async {
    final video = _featured;
    if (video == null || _playingFeatured) return;
    setState(() => _playingFeatured = true);
    final error = await launchPlayer(
      context,
      video,
      startAt: PlaybackProgress.instance.resumePosition(video.id),
      queue: List<Video>.of(_videos),
    );
    if (!mounted) return;
    setState(() => _playingFeatured = false);
    if (error != null) _toast(error);
  }

  void _changeCategory(String value) {
    if (value == _category) return;
    setState(() => _category = value);
    _loadPage(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    // The body extends behind the translucent tab bar; keep a scroll inset so
    // the last card can still be brought fully above the glass surface.
    final bottomInset = kBottomBarHeight + context.safe.bottom;
    final featured = _featured;
    final showCategories = _categories.length > 1;
    final firstLoad = _videos.isEmpty && _loading;
    final resume = featured == null
        ? null
        : PlaybackProgress.instance.resumePosition(featured.id);
    final screen = MediaQuery.sizeOf(context);
    _heroLimit = math.min(screen.height * 0.48, 450.0).toDouble() + context.safe.top + Gaps.sm - 30;
    final darkMode = AppColors.palette.brightness == Brightness.dark;

    final libraryActive = _section == _Section.library;
    final settingsActive = _section == _Section.settings;
    final libraryVisible = libraryActive || _dragTarget == _Section.library;
    final settingsVisible = settingsActive || _dragTarget == _Section.settings;
    if (libraryVisible || _libraryPage != null) {
      _libraryPage = LibraryView(
        key: const ValueKey<String>('library'),
        bottomInset: bottomInset,
        onOpen: _openDetails,
        onBrowse: () => _transitionToSection(_Section.home),
        segmentRequest: _libraryRequest,
      );
    }
    if (settingsVisible || _settingsPage != null) {
      _settingsPage = SettingsView(
        key: const ValueKey<String>('settings'),
        bottomInset: bottomInset,
      );
    }

    final pageWidth = screen.width;
    final previewOffset = _dragOffset + (_dragOffset < 0 ? pageWidth : -pageWidth);
    Widget sectionWidget(_Section section) {
      switch (section) {
        case _Section.home:
          return _buildHome(
            margin,
            bottomInset,
            featured,
            showCategories,
            firstLoad,
            resume,
          );
        case _Section.library:
          return _libraryPage ?? const SizedBox.shrink();
        case _Section.settings:
          return _settingsPage ?? const SizedBox.shrink();
      }
    }

    Widget positionedSection(_Section section) {
      final isCurrent = section == _section;
      final isPreview = section == _dragTarget;
      final visible = isCurrent || isPreview;
      final offset = isCurrent
          ? _dragOffset
          : (isPreview ? previewOffset : 0.0);
      return Positioned.fill(
        child: Transform.translate(
          offset: Offset(offset, 0),
          child: _SectionHost(
            key: _sectionHostKeys[section],
            active: visible,
            child: IgnorePointer(
              ignoring: !isCurrent || _dragOffset.abs() > 1,
              child: RepaintBoundary(child: sectionWidget(section)),
            ),
          ),
        ),
      );
    }

    final orderedLayers = <Widget>[
      for (final section in _sectionOrder)
        if (section != _section && section != _dragTarget)
          positionedSection(section),
      positionedSection(_section),
      if (_dragTarget != null) positionedSection(_dragTarget!),
    ];
    final content = RepaintBoundary(
      child: ClipRect(
        child: Stack(fit: StackFit.expand, children: orderedLayers),
      ),
    );

    return ValueListenableBuilder<bool>(
      valueListenable: _search,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        onHorizontalDragCancel: _onHorizontalDragCancel,
        child: content,
      ),
      builder: (context, searchOpen, page) {
        final lightIcons = darkMode ||
            (_section == _Section.home && !searchOpen && _heroVisible);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: lightIcons
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: PopScope(
            canPop: !searchOpen && _section == _Section.home,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _handleBack();
            },
            child: Scaffold(
              backgroundColor: AppColors.background,
              extendBody: true,
              resizeToAvoidBottomInset: false,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  page!,
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: searchOpen
                        ? SearchOverlay(
                            key: const ValueKey<String>('search'),
                            bottomInset: bottomInset,
                            onClose: _closeSearch,
                            onOpen: _openDetails,
                          )
                        : const SizedBox.shrink(
                            key: ValueKey<String>('no-search'),
                          ),
                  ),
                ],
              ),
              bottomNavigationBar: _RidingTabBar(
                selected: searchOpen
                    ? AppTab.search
                    : switch (_dragTarget ?? _section) {
                        _Section.home => AppTab.home,
                        _Section.library => AppTab.library,
                        _Section.settings => AppTab.settings,
                      },
                onSelect: _onTabSelect,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHome(
    double margin,
    double bottomInset,
    Video? featured,
    bool showCategories,
    bool firstLoad,
    Duration? resume,
  ) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      edgeOffset: context.safe.top + Gaps.sm,
      displacement: 44,
      child: CustomScrollView(
      key: const PageStorageKey<String>('home-scroll'),
      controller: _scroll,
      physics: nativeScrollPhysics(context, alwaysScrollable: true),
      scrollCacheExtent: ScrollCacheExtent.pixels(
        MediaQuery.sizeOf(context).height,
      ),
      slivers: [
        SliverToBoxAdapter(
          child: HomeHero(
            video: featured,
            loading: firstLoad,
            playLabel: resume != null ? 'Resume' : 'Play',
            playBusy: _playingFeatured,
            onPlay: _playFeatured,
            onDetails: () {
              if (featured != null) {
                _openDetails(featured, List<Video>.of(_videos));
              }
            },
          ),
        ),
        SliverToBoxAdapter(child: ContinueRow(onPlay: _resume)),
        if (showCategories)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: Gaps.xs),
              child: CategoryBar(
                categories: _categories,
                selected: _category,
                onSelected: _changeCategory,
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(margin, Gaps.md, margin, Gaps.md),
            child: Text(
              _category == 'All' ? 'Latest videos' : _category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.headline,
            ),
          ),
        ),
        ..._contentSlivers(margin),
        SliverToBoxAdapter(child: SizedBox(height: Gaps.xl + bottomInset)),
      ],
      ),
    );
  }

  List<Widget> _contentSlivers(double margin) {
    final gridPadding = EdgeInsets.symmetric(horizontal: margin);

    if (_videos.isEmpty && _loading) {
      return [SliverSkeletonGrid(padding: gridPadding)];
    }

    final error = _error;
    if (_videos.isEmpty && error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: error.icon,
            title: error.title,
            message: error.message,
            actionLabel: 'Retry',
            onAction: () => _loadPage(reset: true),
            secondaryLabel: error.offline &&
                    DownloadStore.instance.items.any(
                      (item) => item.status == DownloadStatus.done,
                    )
                ? 'Open downloads'
                : null,
            onSecondary: _showDownloads,
          ),
        ),
      ];
    }

    if (_videos.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: Icons.video_library_outlined,
            title: 'No videos found',
            message: _category == 'All'
                ? 'There is nothing to show right now.'
                : 'There are no videos in \u201c$_category\u201d yet.',
            actionLabel: 'Refresh',
            onAction: () => _loadPage(reset: true),
          ),
        ),
      ];
    }

    return [
      if (_gridVideos.isNotEmpty)
        SliverVideoGrid(
          videos: _gridVideos,
          padding: gridPadding,
          onOpen: (video) => _openDetails(video, List<Video>.of(_videos)),
        ),
      if (_loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: Gaps.lg),
            child: Spinner(),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: Gaps.lg),
            child: Center(
              child: AppButton(
                label: 'Couldn\u2019t load more \u2013 Retry',
                icon: Icons.refresh_rounded,
                style: AppButtonStyle.secondary,
                onPressed: _loadPage,
              ),
            ),
          ),
        ),
    ];
  }
}

class _SectionHost extends StatelessWidget {
  const _SectionHost({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active,
      child: TickerMode(enabled: active, child: child),
    );
  }
}

class _RidingTabBar extends StatelessWidget {
  const _RidingTabBar({required this.selected, required this.onSelect});

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    // Reserve only the dock's real height plus the iPhone home-indicator area.
    // Never let a loose Center claim the full Scaffold height.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: kBottomBarHeight + safeBottom,
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(bottom: safeBottom),
          child: AppBottomBar(
            selected: selected,
            onSelect: onSelect,
            bottomGap: 0,
          ),
        ),
      ),
    );
  }
}
