import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'error_text.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'preview_manager.dart';
import 'recent_history_view.dart';
import 'recent_videos_store.dart';
import 'settings_view.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/category_bar.dart';
import 'widgets/favorites_view.dart';
import 'widgets/home_hero.dart';
import 'widgets/search_overlay.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

enum _Section { home, favorites, history, settings }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _pageSize = 12;

  /// Stop paginating after this many consecutive pages that added nothing new.
  static const int _maxEmptyPages = 3;

  static const String _hintsKey = 'hints_v1';

  // One controller for the whole page: hero, chips and grid scroll together.
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
  bool _searchOpen = false;
  _Section _section = _Section.home;
  FriendlyError? _error;

  List<String> get _categories => <String>['All', ...videoRepository.categories];

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onSettingsChanged);
    _scroll.addListener(_maybeLoadMore);
    _loadPage(reset: true);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------------

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 800) _loadPage();
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || !_hasMore || !_scroll.hasClients) return;
      // Short first pages: keep loading so the viewer can always scroll.
      if (_scroll.position.maxScrollExtent < 100) _loadPage();
    });
  }

  void _recomputeDerived() {
    _featured = _videos.isNotEmpty ? _videos.first : null;
    _gridVideos = _videos.length > 1
        ? List<Video>.unmodifiable(_videos.skip(1))
        : const <Video>[];
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading && !reset) return;
    final requestGeneration = reset ? ++_generation : _generation;
    final requestedPage = reset ? 0 : _page;

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
      final result = await videoRepository.getVideos(
        page: requestedPage,
        pageSize: _pageSize,
        category: _category == 'All' ? null : _category,
      );
      if (!mounted || requestGeneration != _generation) return;

      final seenIds = _videos.map((video) => video.id).toSet();
      final fresh = <Video>[];
      for (final video in result) {
        if (seenIds.add(video.id)) fresh.add(video);
      }

      setState(() {
        _videos.addAll(fresh);
        _recomputeDerived();
        _page = requestedPage + 1;
        // A page of only duplicates must not end pagination by itself; only
        // an empty source or repeated duplicates do.
        _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
        _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
        _loading = false;
      });
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

  /// One-time tip that explains the long-press preview.
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

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  void _scrollToTop() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    _scroll.animateTo(0, duration: Motion.scroll, curve: Motion.curve);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          margin: EdgeInsets.fromLTRB(
            Gaps.lg,
            0,
            Gaps.lg,
            kBottomBarHeight + context.safe.bottom,
          ),
        ),
      );
  }

  /// Return to the main feed before allowing the system to leave the app.
  void _handleBack() {
    if (_searchOpen) {
      _closeSearch();
    } else if (_section != _Section.home) {
      setState(() => _section = _Section.home);
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text('This removes recently played videos and progress.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    RecentVideosStore.instance.clear();
    PlaybackProgress.instance.clearAll();
    if (mounted) _toast('Watch history cleared');
  }

  void _openSearch() {
    if (_searchOpen) return;
    PreviewManager.instance.stopNow(fade: false);
    setState(() => _searchOpen = true);
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _searchOpen = false);
  }

  Future<void> _openDetails(Video video, List<Video> queue) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: queue),
      ),
    );
    if (!mounted) return;
    setState(() {}); // Refresh progress, watched and favourite marks.
  }

  void _onTabSelect(AppTab tab) {
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
      case AppTab.history:
        if (_searchOpen) _closeSearch();
        setState(() => _section = _Section.history);
      case AppTab.favorites:
        if (_searchOpen) _closeSearch();
        setState(() => _section = _Section.favorites);
      case AppTab.settings:
        if (_searchOpen) _closeSearch();
        setState(() => _section = _Section.settings);
    }
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

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final bottomInset = kBottomBarHeight + context.safe.bottom;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final featured = _featured;
    final showCategories = _categories.length > 1;
    final firstLoad = _videos.isEmpty && _loading;
    final resume = featured == null
        ? null
        : PlaybackProgress.instance.resumePosition(featured.id);

    return PopScope(
      canPop: !_searchOpen && _section == _Section.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        // The search screen owns the keyboard; nothing may resize under it.
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The page keeps its scroll position while the search is open.
            AnimatedSwitcher(
              duration: Motion.normal,
              child: switch (_section) {
                _Section.favorites => FavoritesView(
                    key: const ValueKey<String>('favorites'),
                    bottomInset: bottomInset,
                    onOpen: _openDetails,
                    onBrowse: () => setState(() => _section = _Section.home),
                  ),
                _Section.history => RecentHistoryView(
                    key: const ValueKey<String>('history'),
                    bottomInset: bottomInset,
                    onOpen: _openDetails,
                    onClear: _clearHistory,
                  ),
                _Section.settings => SettingsView(
                    key: const ValueKey<String>('settings'),
                    bottomInset: bottomInset,
                  ),
                _Section.home => KeyedSubtree(
                    key: const ValueKey<String>('home'),
                    child: _buildHome(
                      margin,
                      bottomInset,
                      featured,
                      showCategories,
                      firstLoad,
                      resume,
                    ),
                  ),
              },
            ),
            // Search fades in and out instead of popping.
            AnimatedSwitcher(
              duration: Motion.normal,
              child: _searchOpen
                  ? SearchOverlay(
                      key: const ValueKey<String>('search'),
                      bottomInset: bottomInset,
                      onClose: _closeSearch,
                      onOpen: _openDetails,
                    )
                  : const SizedBox.shrink(key: ValueKey<String>('no-search')),
            ),
            // Hidden while the keyboard is up (it would ride on top of it).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedSlide(
                duration: Motion.normal,
                curve: Motion.curve,
                offset: keyboardOpen ? const Offset(0, 1.5) : Offset.zero,
                child: AnimatedOpacity(
                  duration: Motion.normal,
                  opacity: keyboardOpen ? 0 : 1,
                  child: IgnorePointer(
                    ignoring: keyboardOpen,
                    child: AppBottomBar(
                      selected: _searchOpen
                          ? AppTab.search
                          : switch (_section) {
                              _Section.home => AppTab.home,
                              _Section.favorites => AppTab.favorites,
                              _Section.history => AppTab.history,
                              _Section.settings => AppTab.settings,
                            },
                      onSelect: _onTabSelect,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
    return CustomScrollView(
      // Restores the scroll position when coming back from Favorites.
      key: const PageStorageKey<String>('home-scroll'),
      controller: _scroll,
      cacheExtent: MediaQuery.sizeOf(context).height,
      slivers: [
        // Pull down to refresh (native iOS spinner).
        CupertinoSliverRefreshControl(
          onRefresh: () => _loadPage(reset: true),
        ),
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
