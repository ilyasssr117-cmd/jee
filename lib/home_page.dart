import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'search_results_page.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/category_bar.dart';
import 'widgets/home_hero.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';
import 'widgets/video_grid.dart';

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
  final FocusNode _searchNode = FocusNode(debugLabel: 'Search');

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
  FriendlyError? _error;
  DateTime? _lastBackPress;

  List<String> get _categories => <String>['All', ...videoRepository.categories];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _heroPlayNode.dispose();
    _searchNode.dispose();
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
    _initialFocusClaimed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute) return;
      final primary = FocusManager.instance.primaryFocus;
      final unclaimed = primary == null ||
          primary is FocusScopeNode ||
          identical(primary, _searchNode);
      if (unclaimed) _heroPlayNode.requestFocus();
    });
  }

  /// After returning from another route, make sure focus is somewhere sensible
  /// if the route's own focus restoration didn't kick in.
  void _restoreFocusIfLost() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) {
        (_featured != null ? _heroPlayNode : _searchNode).requestFocus();
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
    final scrolled = _scroll.hasClients && _scroll.offset > 8;
    if (scrolled) {
      _scrollToTop();
      (_featured != null ? _heroPlayNode : _searchNode).requestFocus();
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

  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SearchResultsPage()),
    );
    if (!mounted) return;
    setState(() {}); // Refresh progress bars.
    _restoreFocusIfLost();
  }

  Future<void> _openDetails(Video video) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => VideoDetailsPage(video: video)),
    );
    if (!mounted) return;
    setState(() {});
    _restoreFocusIfLost();
  }

  Future<void> _playFeatured() async {
    final video = _featured;
    if (video == null || _playingFeatured) return;
    setState(() => _playingFeatured = true);
    final error = await launchPlayer(
      context,
      video,
      startAt: PlaybackProgress.instance.resumePosition(video.id),
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
    final margin = context.s(Gaps.screenH);
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
        body: CustomScrollView(
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
                searchNode: _searchNode,
                onPlay: _playFeatured,
                onDetails: () {
                  if (featured != null) _openDetails(featured);
                },
                onSearch: _openSearch,
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
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  context.s(showCategories ? Gaps.sm : Gaps.md),
                  margin,
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
            ..._contentSlivers(margin),
            SliverToBoxAdapter(child: SizedBox(height: context.s(Gaps.xxl))),
          ],
        ),
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
          child: TvStatusView(
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
      ];
    }

    return [
      if (_gridVideos.isNotEmpty)
        SliverVideoGrid(
          videos: _gridVideos,
          padding: gridPadding,
          onOpen: _openDetails,
          onItemFocus: (index) {
            if (index >= _gridVideos.length - 4) _loadPage();
          },
        ),
      if (_loading)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: context.s(Gaps.lg)),
            child: const TvSpinner(size: 32),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: context.s(Gaps.lg)),
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
