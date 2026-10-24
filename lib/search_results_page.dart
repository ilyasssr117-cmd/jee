import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';
import 'widgets/video_grid.dart';

class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({super.key});

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  static const int _pageSize = 12;
  static const int _maxEmptyPages = 3;

  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _submitNode = FocusNode(debugLabel: 'Search submit');
  final FocusNode _firstResultNode = FocusNode(debugLabel: 'First result');

  // The field handles its own D-pad keys so it can never trap focus.
  late final FocusNode _fieldNode = FocusNode(
    debugLabel: 'Search field',
    onKeyEvent: _handleFieldKey,
  );

  final List<Video> _videos = <Video>[];
  String _query = '';
  int _page = 0;
  int _generation = 0;
  int _emptyPages = 0;
  bool _loading = false;
  bool _hasMore = false;
  bool _awaitingResultsFocus = false;
  FriendlyError? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _text.dispose();
    _fieldNode.dispose();
    _submitNode.dispose();
    _firstResultNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Remote handling
  // -------------------------------------------------------------------------

  /// Arrow keys inside a text field normally move the caret and can strand the
  /// D-pad. Up/down always leave the field; left/right leave it at the edges.
  KeyEventResult _handleFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final selection = _text.selection;
    final atStart =
        !selection.isValid || (selection.isCollapsed && selection.extentOffset <= 0);
    final atEnd = !selection.isValid ||
        (selection.isCollapsed && selection.extentOffset >= _text.text.length);

    TraversalDirection? direction;
    if (key == LogicalKeyboardKey.arrowDown) {
      direction = TraversalDirection.down;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      direction = TraversalDirection.up;
    } else if (key == LogicalKeyboardKey.arrowRight && atEnd) {
      direction = TraversalDirection.right;
    } else if (key == LogicalKeyboardKey.arrowLeft && atStart) {
      direction = TraversalDirection.left;
    }

    if (direction == null) return KeyEventResult.ignored;
    node.focusInDirection(direction);
    return KeyEventResult.handled;
  }

  /// BACK from the results returns to the search controls first; BACK from the
  /// controls leaves the page.
  void _handleBack() {
    final inControls = _fieldNode.hasFocus || _submitNode.hasFocus;
    if (!inControls && (_videos.isNotEmpty || _query.isNotEmpty)) {
      if (_scroll.hasClients && _scroll.offset > 0) {
        _scroll.animateTo(0, duration: Motion.scroll, curve: Motion.curve);
      }
      _submitNode.requestFocus();
      return;
    }
    Navigator.of(context).pop();
  }

  void _focusResultsIfWaiting() {
    if (!_awaitingResultsFocus || _videos.isEmpty) return;
    _awaitingResultsFocus = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      final unclaimed = primary == null ||
          primary is FocusScopeNode ||
          identical(primary, _submitNode);
      if (unclaimed && _firstResultNode.context != null) {
        _firstResultNode.requestFocus();
      }
    });
  }

  // -------------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------------

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    if (_scroll.position.maxScrollExtent - _scroll.position.pixels < 800) {
      _loadPage();
    }
  }

  void _submit() {
    final normalized = _text.text.trim();
    // Keep a focus anchor while the keyboard closes and results load.
    _submitNode.requestFocus();
    if (_loading && normalized == _query) return;
    _query = normalized;
    _awaitingResultsFocus = true;
    _loadPage(reset: true);
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = reset ? ++_generation : _generation;

    if (reset && _query.isEmpty) {
      setState(() {
        _videos.clear();
        _page = 0;
        _emptyPages = 0;
        _loading = false;
        _hasMore = false;
        _error = null;
        _awaitingResultsFocus = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _videos.clear();
        _page = 0;
        _emptyPages = 0;
        _hasMore = true;
      }
    });

    try {
      final result = await videoRepository.searchVideos(
        query: _query,
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted || generation != _generation) return;

      final seen = _videos.map((video) => video.id).toSet();
      final fresh = <Video>[];
      for (final video in result) {
        if (seen.add(video.id)) fresh.add(video);
      }

      setState(() {
        _videos.addAll(fresh);
        _page++;
        _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
        _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
        _loading = false;
      });
      _focusResultsIfWaiting();
      if (_videos.isEmpty) _awaitingResultsFocus = false;

      if (_hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _loading || !_hasMore || !_scroll.hasClients) return;
          if (_scroll.position.maxScrollExtent < 120) _loadPage();
        });
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _hasMore = false;
        _awaitingResultsFocus = false;
        _error = describeError(error, subject: 'search results');
      });
    }
  }

  Future<void> _openDetails(Video video) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => VideoDetailsPage(video: video)),
    );
    if (mounted) setState(() {}); // Refresh progress bars.
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final margin = context.s(Gaps.screenH);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                margin,
                context.s(Gaps.screenV + Gaps.sm),
                margin,
                context.s(Gaps.md),
              ),
              child: _buildSearchRow(),
            ),
            Expanded(
              child: CustomScrollView(
                controller: _scroll,
                cacheExtent: MediaQuery.sizeOf(context).height,
                slivers: _resultSlivers(margin),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: _fieldNode,
            builder: (context, _) {
              final focused = _fieldNode.hasFocus;
              return AnimatedContainer(
                duration: Motion.quick,
                height: context.s(58),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(context.s(Radii.field)),
                  border: Border.all(
                    color: focused ? AppColors.focusRing : AppColors.outline,
                    width: 2.5,
                  ),
                ),
                child: TextField(
                  controller: _text,
                  focusNode: _fieldNode,
                  autofocus: true,
                  maxLines: 1,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submit(),
                  cursorColor: AppColors.accent,
                  style: AppText.title.copyWith(fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search titles or keywords',
                    hintStyle: AppText.title.copyWith(
                      fontWeight: FontWeight.w400,
                      color: AppColors.textTertiary,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: context.s(28),
                      color: AppColors.textSecondary,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: context.s(Gaps.md),
                      vertical: context.s(14),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(width: context.s(Gaps.md)),
        TvButton(
          label: 'Search',
          focusNode: _submitNode,
          scrollAlignment: null,
          onPressed: _submit,
        ),
      ],
    );
  }

  List<Widget> _resultSlivers(double margin) {
    final gridPadding = EdgeInsets.fromLTRB(
      margin,
      context.s(Gaps.sm),
      margin,
      context.s(Gaps.xxl),
    );

    if (_query.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: const TvStatusView(
            icon: Icons.search_rounded,
            title: 'Search for videos',
            message: 'Type a title or keyword, then press Search.',
          ),
        ),
      ];
    }

    final title = SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(margin, context.s(Gaps.sm), margin, context.s(Gaps.sm)),
        child: Text(
          'Results for \u201c$_query\u201d',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.headline,
        ),
      ),
    );

    if (_videos.isEmpty && _loading) {
      return [title, SliverSkeletonGrid(padding: gridPadding)];
    }

    final error = _error;
    if (_videos.isEmpty && error != null) {
      return [
        title,
        SliverFillRemaining(
          hasScrollBody: false,
          child: TvStatusView(
            icon: error.icon,
            title: error.title,
            message: error.message,
            actionLabel: 'Retry',
            autofocus: false,
            onAction: () => _loadPage(reset: true),
          ),
        ),
      ];
    }

    if (_videos.isEmpty) {
      return [
        title,
        SliverFillRemaining(
          hasScrollBody: false,
          child: TvStatusView(
            icon: Icons.search_off_rounded,
            title: 'No results found',
            message: 'Check the spelling or try a different keyword.',
            actionLabel: 'Edit search',
            actionIcon: Icons.edit_rounded,
            autofocus: false,
            onAction: () => _fieldNode.requestFocus(),
          ),
        ),
      ];
    }

    return [
      title,
      SliverVideoGrid(
        videos: _videos,
        padding: gridPadding,
        firstItemFocusNode: _firstResultNode,
        onOpen: _openDetails,
        onItemFocus: (index) {
          if (index >= _videos.length - 4) _loadPage();
        },
      ),
      if (_loading)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: context.s(Gaps.xl)),
            child: const TvSpinner(size: 32),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: context.s(Gaps.xl)),
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
