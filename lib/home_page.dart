import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/category_bar.dart';
import 'widgets/favorites_view.dart';
import 'widgets/home_hero.dart';
import 'widgets/search_overlay.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';
import 'widgets/video_grid.dart';

enum _Section { home, favorites }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _pageSize = 12;

  /// Stop paginating after this many consecutive pages that added nothing new.
  static const int _maxEmptyPages = 3;

  static const Duration _exitWindow = Duration(seconds: 2);

  // One controller for the whole page: hero, chips and grid scroll together.
  final ScrollController _scroll = ScrollController();
  final FocusNode _heroPlayNode = FocusNode(debugLabel: 'Hero play');
  final FocusNode _sideHomeNode = FocusNode(debugLabel: 'Sidebar home');
  final FocusNode _sideSearchNode = FocusNode(debugLabel: 'Sidebar search');
  final FocusNode _sideFavoritesNode = FocusNode(debugLabel: 'Sidebar favorites');

  final List<Video> _videos = <Video>[];
  Video? _featured;
  List<Video> _gridVideos = const <Video>[];

  int _page = 0;
  int _generation = 0;
  int _emptyPages = 0;
  String _category = 'All';
  bool _loading = false;
  bool _hasMore = true;
  bool _initialFocusClaimed = false;
  bool _playingFeatured = false;
  bool _searchOpen = false;
  _Section _section = _Section.home;
  FocusNode? _focusBeforeSearch;
  FocusNode? _lastContentFocus; // Last card / chip / hero button focused.
  final GlobalKey<SearchOverlayState> _searchKey =
      GlobalKey<SearchOverlayState>();
  FriendlyError? _error;
  DateTime? _lastBackPress;

  List<String> get _categories => <String>['All', ...videoRepository.categories];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    FocusManager.instance.addListener(_trackContentFocus);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_trackContentFocus);
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _heroPlayNode.dispose();
    _sideHomeNode.dispose();
    _sideSearchNode.dispose();
    _sideFavoritesNode.dispose();
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
        // A page of only duplicates (e.g. home page vs. page 1) must not end
        // pagination by itself; only an empty source or repeated duplicates do.
        _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
        _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
        _loading = false;
      });
      _claimInitialFocus();
      if (_hasMore) _scheduleFillViewport();
    } catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      setState(() {
        _loading = false;
        _hasMore = false;
        _error = describeError(error);
      });
    }
  }

  // -------------------------------------------------------------------------
  // Focus & navigation
  // -------------------------------------------------------------------------

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent ?? false;

  /// Gives the featured Play button focus the first time content appears, as
  /// long as the viewer hasn't already moved focus somewhere else.
  void _claimInitialFocus() {
    if (_initialFocusClaimed || _featured == null) return;
    if (_searchOpen || _section != _Section.home) return;
    _initialFocusClaimed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute || _searchOpen) return;
      final primary = FocusManager.instance.primaryFocus;
      final unclaimed = primary == null ||
          primary is FocusScopeNode;
      if (unclaimed) _heroPlayNode.requestFocus();
    });
  }

  /// After returning from another route, make sure focus is somewhere sensible
  /// if the route's own focus restoration didn't kick in.
  void _restoreFocusIfLost() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute || _searchOpen) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) {
        if (_section == _Section.favorites) {
          _sideFavoritesNode.requestFocus();
        } else {
          (_featured != null ? _heroPlayNode : _sideHomeNode).requestFocus();
        }
      }
    });
  }

  void _scrollToTop() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    _scroll.animateTo(0, duration: Motion.scroll, curve: Motion.curve);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: _exitWindow),
      );
  }

  /// BACK on the home page: first return to the top, then ask for a second
  /// press before leaving the app.
  void _handleBack() {
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    if (_section == _Section.favorites) {
      _showHome();
      _sideHomeNode.requestFocus();
      return;
    }
    final scrolled = _scroll.hasClients && _scroll.offset > 8;
    if (scrolled) {
      _scrollToTop();
      (_featured != null ? _heroPlayNode : _sideHomeNode).requestFocus();
      return;
    }

    final now = DateTime.now();
    final last = _lastBackPress;
    if (last != null && now.difference(last) < _exitWindow) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    _toast('Press Back again to exit');
  }

  /// Remembers the last thing focused on the page itself (not the sidebar, not
  /// the search), so BACK from search can return the viewer to exactly there.
  void _trackContentFocus() {
    if (!mounted || _searchOpen || !_isCurrentRoute) return;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode) return;
    if (identical(node, _sideHomeNode) ||
        identical(node, _sideSearchNode) ||
        identical(node, _sideFavoritesNode)) {
      return;
    }
    _lastContentFocus = node;
  }

  /// Search is an overlay on this page: no route, the page stays underneath.
  void _openSearch() {
    if (_searchOpen) {
      // Search pressed again in the sidebar: just go back to the field.
      _searchKey.currentState?.focusField();
      return;
    }
    final remembered = _lastContentFocus;
    _focusBeforeSearch = (remembered != null &&
            remembered.context != null &&
            remembered.canRequestFocus)
        ? remembered
        : FocusManager.instance.primaryFocus;
    setState(() => _searchOpen = true);
  }

  /// Closing returns focus to exactly where it was; scroll never moved.
  /// With [restoreFocus] false the caller moves focus itself (sidebar jumps).
  void _closeSearch({bool restoreFocus = true}) {
    if (!_searchOpen) return;
    final previous = _focusBeforeSearch;
    _focusBeforeSearch = null;
    setState(() => _searchOpen = false);
    if (!restoreFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute) return;
      final anchor = previous?.context;
      if (previous != null &&
          anchor != null &&
          anchor.mounted &&
          previous.canRequestFocus) {
        previous.requestFocus();
        return;
      }
      _restoreFocusIfLost();
    });
  }

  Future<void> _openDetails(Video video, List<Video> queue) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: queue),
      ),
    );
    if (!mounted) return;
    setState(() {}); // Refresh progress, watched and favourite marks.
    _restoreFocusIfLost();
  }

  void _showHome() {
    if (_section == _Section.home) {
      _scrollToTop();
      return;
    }
    setState(() => _section = _Section.home);
  }

  void _showFavorites() {
    if (_section == _Section.favorites) return;
    setState(() => _section = _Section.favorites);
  }

  void _onSidebarSelect(SidebarItem item) {
    // Leaving the search through the sidebar: close it first and land on the
    // chosen section, with the focus staying on that sidebar button.
    if (_searchOpen && item != SidebarItem.search) {
      _closeSearch(restoreFocus: false);
      if (item == SidebarItem.home) {
        if (_section != _Section.home) {
          setState(() => _section = _Section.home);
        }
        _sideHomeNode.requestFocus();
      } else {
        if (_section != _Section.favorites) {
          setState(() => _section = _Section.favorites);
        }
        _sideFavoritesNode.requestFocus();
      }
      return;
    }
    switch (item) {
      case SidebarItem.home:
        _showHome();
      case SidebarItem.search:
        _openSearch();
      case SidebarItem.favorites:
        _showFavorites();
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
    _restoreFocusIfLost();
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
    final phone = context.isPhone;
    // TV: sidebar at the right edge. Phone: bar at the bottom.
    final inset = phone ? 0.0 : context.s(kSidebarWidth);
    final bottomInset =
        phone ? context.s(kBottomBarHeight) + context.safe.bottom : 0.0;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final featured = _featured;
    final showCategories = _categories.length > 1;
    final firstLoad = _videos.isEmpty && _loading;
    final resume = featured == null
        ? null
        : PlaybackProgress.instance.resumePosition(featured.id);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Content spans the whole screen; the sidebar floats on top of it.
            // The page below keeps its scroll position and focus, but the
            // D-pad can't reach it while search is open.
            ExcludeFocus(
              excluding: _searchOpen,
              child: _section == _Section.favorites
                  ? FavoritesView(
                      rightInset: inset,
                      bottomInset: bottomInset,
                      onOpen: _openDetails,
                      onBrowse: () {
                        _showHome();
                        _sideHomeNode.requestFocus();
                      },
                    )
                  : _buildHome(
                      margin,
                      inset,
                      bottomInset,
                      featured,
                      showCategories,
                      firstLoad,
                      resume,
                    ),
            ),
            if (_searchOpen)
              SearchOverlay(
                key: _searchKey,
                rightInset: inset,
                bottomInset: 0,
                onClose: _closeSearch,
                onOpen: _openDetails,
              ),
            // Always reachable with the D-pad, also from the search. The blue
            // mark follows the viewer: Home, Search or Favorites.
            // Hidden on phones while the keyboard is up (it would ride on it).
            if (!(phone && keyboardOpen))
              Positioned(
                key: const ValueKey<String>('sidebar'),
                top: phone ? null : 0,
                right: phone ? 0 : 0,
                bottom: 0,
                left: phone ? 0 : null,
                child: AppSidebar(
                  selected: _searchOpen
                      ? SidebarItem.search
                      : (_section == _Section.favorites
                          ? SidebarItem.favorites
                          : SidebarItem.home),
                  onSelect: _onSidebarSelect,
                  homeNode: _sideHomeNode,
                  searchNode: _sideSearchNode,
                  favoritesNode: _sideFavoritesNode,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(
    double margin,
    double inset,
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
      // Build a little beyond the viewport so D-pad navigation can always
      // find the next row / chip.
      cacheExtent: MediaQuery.sizeOf(context).height,
      slivers: [
        SliverToBoxAdapter(
          child: HomeHero(
            video: featured,
            loading: firstLoad,
            playLabel: resume != null ? 'Resume' : 'Play',
            playBusy: _playingFeatured,
            playNode: _heroPlayNode,
            onPlay: _playFeatured,
            onDetails: () {
              if (featured != null) {
                _openDetails(featured, List<Video>.of(_videos));
              }
            },
            onChildFocus: _scrollToTop,
          ),
        ),
        if (showCategories)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: context.s(Gaps.sm)),
              child: CategoryBar(
                categories: _categories,
                selected: _category,
                onSelected: _changeCategory,
                rightInset: inset,
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              margin,
              context.s(showCategories ? Gaps.sm : Gaps.md),
              margin + inset,
              context.s(Gaps.md),
            ),
            child: Text(
              _category == 'All' ? 'Latest videos' : _category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.headline,
            ),
          ),
        ),
        ..._contentSlivers(margin, inset),
        SliverToBoxAdapter(
          child: SizedBox(height: context.s(Gaps.xxl) + bottomInset),
        ),
      ],
    );
  }

  List<Widget> _contentSlivers(double margin, double inset) {
    final gridPadding = EdgeInsets.fromLTRB(margin, 0, margin + inset, 0);

    if (_videos.isEmpty && _loading) {
      return [SliverSkeletonGrid(padding: gridPadding)];
    }

    final error = _error;
    if (_videos.isEmpty && error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.only(right: inset),
            child: TvStatusView(
              icon: error.icon,
              title: error.title,
              message: error.message,
              actionLabel: 'Retry',
              onAction: () => _loadPage(reset: true),
            ),
          ),
        ),
      ];
    }

    if (_videos.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.only(right: inset),
            child: TvStatusView(
              icon: Icons.video_library_outlined,
              title: 'No videos found',
              message: _category == 'All'
                  ? 'There is nothing to show right now.'
                  : 'There are no videos in \u201c$_category\u201d yet.',
              actionLabel: 'Refresh',
              onAction: () => _loadPage(reset: true),
            ),
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
          onItemFocus: (index) {
            if (index >= _gridVideos.length - 4) _loadPage();
          },
        ),
      if (_loading)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: context.s(Gaps.lg), right: inset),
            child: const TvSpinner(size: 32),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: context.s(Gaps.lg), right: inset),
            child: Center(
              child: TvButton(
                label: 'Couldn\u2019t load more \u2013 Retry',
                icon: Icons.refresh_rounded,
                style: TvButtonStyle.secondary,
                onPressed: _loadPage,
              ),
            ),
          ),
        ),
    ];
  }
}
