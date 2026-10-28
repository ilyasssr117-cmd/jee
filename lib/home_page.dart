import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
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

class _HomePageState extends State<HomePage> {
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

  List<String> get _categories => <String>['All', ...videoRepository.categories];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
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
      setState(() => _section = _Section.home);
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

  void _onTabSelect(AppTab tab) {
    PreviewManager.instance.stopNow(fade: false);
    switch (tab) {
      case AppTab.home:
        if (_searchOpen) _closeSearch();
        if (_section == _Section.home) {
          _scrollToTop();
        } else {
          setState(() => _section = _Section.home);
        }
      case AppTab.search:
        _openSearch();
      case AppTab.library:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.library) {
          setState(() => _section = _Section.library);
        }
      case AppTab.settings:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.settings) {
          setState(() => _section = _Section.settings);
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
    final bottomInset = kBottomBarHeight + context.safe.bottom;
    final featured = _featured;
    final showCategories = _categories.length > 1;
    final firstLoad = _videos.isEmpty && _loading;
    final resume = featured == null
        ? null
        : PlaybackProgress.instance.resumePosition(featured.id);
    final screen = MediaQuery.sizeOf(context);
    _heroLimit = math.min(screen.height * 0.42, 380.0) - context.safe.top - 30;
    final darkMode = AppColors.palette.brightness == Brightness.dark;

    final libraryActive = _section == _Section.library;
    final settingsActive = _section == _Section.settings;
    if (libraryActive) {
      _libraryPage = LibraryView(
        key: const ValueKey<String>('library'),
        bottomInset: bottomInset,
        onOpen: _openDetails,
        onBrowse: () => setState(() => _section = _Section.home),
      );
    }
    if (settingsActive) {
      _settingsPage = SettingsView(
        key: const ValueKey<String>('settings'),
        bottomInset: bottomInset,
      );
    }
    final content = RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _SectionHost(
            key: const ValueKey<String>('home'),
            active: _section == _Section.home,
            child: _buildHome(
              margin,
              bottomInset,
              featured,
              showCategories,
              firstLoad,
              resume,
            ),
          ),
          if (_libraryPage != null)
            _SectionHost(
              key: const ValueKey<String>('library-host'),
              active: libraryActive,
              child: _libraryPage!,
            ),
          if (_settingsPage != null)
            _SectionHost(
              key: const ValueKey<String>('settings-host'),
              active: settingsActive,
              child: _settingsPage!,
            ),
        ],
      ),
    );

    return ValueListenableBuilder<bool>(
      valueListenable: _search,
      child: content,
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
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _RidingTabBar(
                        selected: searchOpen
                            ? AppTab.search
                            : switch (_section) {
                                _Section.home => AppTab.home,
                                _Section.library => AppTab.library,
                                _Section.settings => AppTab.settings,
                              },
                        onSelect: _onTabSelect,
                      ),
                    ),
                  ),
                ],
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
      physics: const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
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

class _SectionHost extends StatefulWidget {
  const _SectionHost({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_SectionHost> createState() => _SectionHostState();
}

class _SectionHostState extends State<_SectionHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: Motion.normal,
    value: widget.active ? 1 : 0,
  );

  @override
  void didUpdateWidget(_SectionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _fade.forward(from: 0);
    } else {
      _fade.value = 0;
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !widget.active,
      child: TickerMode(
        enabled: widget.active,
        child: FadeTransition(opacity: _fade, child: widget.child),
      ),
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
    final restingGap = math.max(context.safe.bottom - 4, 10.0);
    final gap = math.max(10.0, restingGap - keyboard);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: AppBottomBar(
        selected: selected,
        onSelect: onSelect,
        bottomGap: gap,
      ),
    );
  }
}
