import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../error_text.dart';
import '../models.dart';
import '../search_history.dart';
import '../tv_focusable.dart';
import '../video_repository.dart';
import 'state_views.dart';
import 'tv_button.dart';
import 'video_grid.dart';

/// Blur behind the overlay. Costs GPU time on every repainted frame, so set
/// this to false first if the weakest TV box stutters while results scroll;
/// the dark scrim alone then does the job.
const bool kSearchBackdropBlur = false;

/// Soft blue glow of the focused search bar (as in the reference design).
const Color _kGlow = AppColors.glowBlue;

/// Full-screen search that lives *on top of* the home page (no route).
///
/// * Live search: results follow the text after a short typing pause.
/// * Recent searches: shown while the field is empty. Plain history only,
///   never suggestions or autocomplete.
/// * Closing is the owner's job ([onClose]); the page underneath is never
///   rebuilt or scrolled by this widget, so the viewer returns to the same
///   spot.
class SearchOverlay extends StatefulWidget {
  const SearchOverlay({
    super.key,
    required this.onClose,
    required this.onOpen,
    this.rightInset = 0,
    this.bottomInset = 0,
  });

  /// Space kept free at the bottom.
  final double bottomInset;

  final VoidCallback onClose;

  /// Space kept free at the right edge (the floating sidebar).
  final double rightInset;

  /// Opens [video]; [queue] is the current result list (Autoplay Next).
  final void Function(Video video, List<Video> queue) onOpen;

  @override
  State<SearchOverlay> createState() => SearchOverlayState();
}

class SearchOverlayState extends State<SearchOverlay> {
  /// Wait for a typing pause before hitting the network.
  static const Duration _debounce = Duration(milliseconds: 450);
  static const int _pageSize = 12;
  static const int _maxEmptyPages = 3;

  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _closeNode = FocusNode(debugLabel: 'Search close');
  final FocusNode _firstResultNode = FocusNode(debugLabel: 'First result');
  final FocusNode _firstRecentNode = FocusNode(debugLabel: 'First recent');

  // The field handles its own D-pad keys so it can never trap focus.
  late final FocusNode _fieldNode = FocusNode(
    debugLabel: 'Search field',
    onKeyEvent: _handleFieldKey,
  );

  Timer? _debounceTimer;
  final List<Video> _videos = <Video>[];
  String _query = '';
  bool _hasText = false;
  bool _awaiting = false; // Text typed, request not started yet.
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
    // Focus goes straight to the search bar.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _generation++; // Ignore any response that is still in flight.
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _text.dispose();
    _fieldNode.dispose();
    _closeNode.dispose();
    _firstResultNode.dispose();
    _firstRecentNode.dispose();
    super.dispose();
  }

  /// Puts the cursor back in the search field (sidebar Search pressed again).
  void focusField() {
    if (mounted) _fieldNode.requestFocus();
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
    final atStart = !selection.isValid ||
        (selection.isCollapsed && selection.extentOffset <= 0);
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

  /// Moves focus onto the first result once the first page lands, but only if
  /// the viewer hasn't already moved somewhere else.
  void _focusResultsIfWaiting() {
    if (!_awaitingResultsFocus || _videos.isEmpty) return;
    _awaitingResultsFocus = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      final unclaimed = primary == null ||
          primary is FocusScopeNode ||
          identical(primary, _closeNode);
      if (unclaimed && _firstResultNode.context != null) {
        _firstResultNode.requestFocus();
      }
    });
  }

  // -------------------------------------------------------------------------
  // Typing → debounced search
  // -------------------------------------------------------------------------

  void _onChanged(String raw) {
    final value = SearchHistory.normalize(raw);
    _debounceTimer?.cancel();

    if (value.isEmpty) {
      _clear();
      return;
    }
    if (value == _query && !_awaiting) return;

    if (!_hasText || !_awaiting) {
      setState(() {
        _hasText = true;
        _awaiting = true;
      });
    }
    // Only the last keystroke of a burst (c → ca → cat) reaches the network.
    _debounceTimer = Timer(_debounce, () => _runSearch(value));
  }

  void _clear() {
    _generation++;
    setState(() {
      _query = '';
      _hasText = false;
      _awaiting = false;
      _videos.clear();
      _page = 0;
      _emptyPages = 0;
      _loading = false;
      _hasMore = false;
      _error = null;
      _awaitingResultsFocus = false;
    });
  }

  void _runSearch(String value) {
    if (!mounted) return;
    _query = value;
    _awaiting = false;
    _loadPage(reset: true);
  }

  /// Enter / the keyboard's search key: search right now and remember it.
  void _submit() {
    _debounceTimer?.cancel();
    final value = SearchHistory.normalize(_text.text);
    if (value.isEmpty) return;
    SearchHistory.instance.add(value);
    // Keep a focus anchor while the keyboard closes and results load.
    _closeNode.requestFocus();
    _awaitingResultsFocus = true;
    if (_loading && value == _query) return;
    setState(() => _hasText = true);
    _runSearch(value);
  }

  void _useRecent(String term) {
    _debounceTimer?.cancel();
    _text.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    SearchHistory.instance.add(term); // Becomes the newest entry.
    _closeNode.requestFocus(); // Anchor: the tapped chip is about to vanish.
    _awaitingResultsFocus = true;
    setState(() => _hasText = true);
    _runSearch(term);
  }

  void _clearRecents() {
    SearchHistory.instance.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldNode.requestFocus();
    });
  }

  void _deleteRecent(String term) {
    SearchHistory.instance.remove(term);
    // The focused × button just disappeared: hand focus to a sensible place.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (SearchHistory.instance.items.isNotEmpty &&
          _firstRecentNode.context != null) {
        _firstRecentNode.requestFocus();
      } else {
        _fieldNode.requestFocus();
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

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = reset ? ++_generation : _generation;

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

  void _openVideo(Video video) {
    // Opening a result is a clear sign this search was useful: remember it.
    SearchHistory.instance.add(_query);
    widget.onOpen(video, List<Video>.of(_videos));
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;

    // No FocusScope of its own: the D-pad must be able to move from the search
    // to the sidebar (Home / Favorites) and back.
    return Stack(
        fit: StackFit.expand,
        children: [
          // Tapping the dimmed area closes the search (mouse / touch).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const _Backdrop(),
          ),
          // The backdrop is static; only the content fades in.
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: Motion.scroll,
            curve: Motion.curve,
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: Padding(
              padding: EdgeInsets.only(right: widget.rightInset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      margin,
                      context.s(Gaps.screenV) + context.safe.top,
                      margin,
                      context.s(Gaps.md),
                    ),
                    child: _buildPanel(),
                  ),
                  Expanded(child: _buildBody(margin)),
                ],
              ),
            ),
          ),
        ],
    );
  }

  /// Glass panel: search bar, and below it the recent searches (which stay
  /// visible while results are shown, like the reference design).
  Widget _buildPanel() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(context.s(28)),
        border: Border.all(color: AppColors.outline),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.s(Gaps.lg)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSearchBar(),
            ListenableBuilder(
              listenable: SearchHistory.instance,
              builder: (context, _) {
                final items = SearchHistory.instance.items;
                if (items.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.only(top: context.s(Gaps.md)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Recent searches', style: AppText.body),
                          SizedBox(width: context.s(Gaps.md)),
                          _ClearAllButton(onTap: _clearRecents),
                        ],
                      ),
                      SizedBox(height: context.s(Gaps.sm + 4)),
                      Wrap(
                        spacing: context.s(Gaps.md),
                        runSpacing: context.s(Gaps.md),
                        children: [
                          for (var i = 0; i < items.length; i++)
                            _RecentChip(
                              key: ValueKey<String>(items[i]),
                              term: items[i],
                              termNode: i == 0 ? _firstRecentNode : null,
                              onSelect: () => _useRecent(items[i]),
                              onDelete: () => _deleteRecent(items[i]),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return ListenableBuilder(
      listenable: _fieldNode,
      builder: (context, _) {
        final focused = _fieldNode.hasFocus;
        return AnimatedContainer(
          duration: Motion.quick,
          height: context.s(72),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1626),
            borderRadius: BorderRadius.circular(context.s(Radii.field + 6)),
            border: Border.all(
              color: focused ? _kGlow : AppColors.outline,
              width: 2.5,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: _kGlow.withValues(alpha: 0.35),
                      blurRadius: context.s(24),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _fieldNode,
                  autofocus: true,
                  maxLines: 1,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _submit(),
                  cursorColor: _kGlow,
                  style: AppText.headline.copyWith(fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search videos',
                    hintStyle: AppText.headline.copyWith(
                      fontWeight: FontWeight.w400,
                      color: AppColors.textTertiary,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: context.s(32),
                      color: AppColors.textPrimary,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: context.s(Gaps.md),
                      vertical: context.s(20),
                    ),
                  ),
                ),
              ),
              _CloseButton(focusNode: _closeNode, onTap: widget.onClose),
              SizedBox(width: context.s(Gaps.md)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(double margin) {
    if (!_hasText) {
      // Recent searches live in the panel above; only hint when there are none.
      return ListenableBuilder(
        listenable: SearchHistory.instance,
        builder: (context, _) => SearchHistory.instance.items.isEmpty
            ? const TvStatusView(
                icon: Icons.search_rounded,
                title: 'Search for videos',
                message: 'Start typing and results appear as you type.',
              )
            : const SizedBox.shrink(),
      );
    }

    final gridPadding = EdgeInsets.fromLTRB(
      margin,
      context.s(Gaps.sm),
      margin,
      context.s(Gaps.xxl),
    );

    final waiting = _awaiting || (_loading && _videos.isEmpty);
    final error = _error;

    final List<Widget> slivers;
    if (waiting && _videos.isEmpty) {
      slivers = [SliverSkeletonGrid(padding: gridPadding)];
    } else if (_videos.isEmpty && error != null) {
      slivers = [
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
    } else if (_videos.isEmpty) {
      slivers = [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: TvStatusView(
            icon: Icons.search_off_rounded,
            title: 'No results found',
            message: 'Check the spelling or try a different keyword.',
          ),
        ),
      ];
    } else {
      slivers = [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              margin,
              context.s(Gaps.sm),
              margin,
              context.s(Gaps.sm),
            ),
            child: Text(
              'Results for \u201c$_query\u201d',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.title,
            ),
          ),
        ),
        SliverVideoGrid(
          videos: _videos,
          padding: gridPadding,
          firstItemFocusNode: _firstResultNode,
          onOpen: _openVideo,
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

    return CustomScrollView(
      controller: _scroll,
      cacheExtent: MediaQuery.sizeOf(context).height,
      slivers: slivers,
    );
  }
}

/// Dark scrim with an optional light blur.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    Widget scrim = const ColoredBox(color: Color(0xE00B0D12));
    if (kSearchBackdropBlur) {
      scrim = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: scrim,
      );
    }
    return SizedBox.expand(child: RepaintBoundary(child: scrim));
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.focusNode, required this.onTap});

  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final size = context.s(44);
    return TvFocusable(
      focusNode: focusNode,
      onTap: onTap,
      scale: 1.08,
      scrollAlignment: null,
      semanticLabel: 'Close search',
      builder: (context, focused) => AnimatedContainer(
        duration: Motion.quick,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused ? AppColors.textPrimary : AppColors.surfaceHigh,
          border: Border.all(
            color: focused ? AppColors.textPrimary : AppColors.outline,
            width: 2,
          ),
        ),
        child: Icon(
          Icons.close_rounded,
          size: context.s(26),
          color: focused ? AppColors.background : AppColors.textPrimary,
        ),
      ),
    );
  }
}

/// "cat ×": the label re-runs the search, the × deletes only this entry.
class _RecentChip extends StatelessWidget {
  const _RecentChip({
    super.key,
    required this.term,
    required this.onSelect,
    required this.onDelete,
    this.termNode,
  });

  final String term;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final FocusNode? termNode;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(context.s(Radii.pill)),
        border: Border.all(color: AppColors.outline, width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.s(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The highlight hugs the word itself (no extra padding).
            TvFocusable(
              focusNode: termNode,
              onTap: onSelect,
              scale: 1.03,
              scrollAlignment: 0.3,
              semanticLabel: term,
              builder: (context, focused) => AnimatedContainer(
                duration: Motion.quick,
                constraints: BoxConstraints(maxWidth: context.s(300)),
                padding: EdgeInsets.symmetric(
                  horizontal: context.s(12),
                  vertical: context.s(5),
                ),
                decoration: BoxDecoration(
                  color: focused ? AppColors.textPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(context.s(Radii.pill)),
                ),
                child: Text(
                  term,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(
                    color:
                        focused ? AppColors.background : AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            TvFocusable(
              onTap: onDelete,
              scale: 1.1,
              scrollAlignment: 0.3,
              semanticLabel: 'Remove $term',
              builder: (context, focused) => AnimatedContainer(
                duration: Motion.quick,
                width: context.s(28),
                height: context.s(28),
                margin: EdgeInsets.only(left: context.s(2)),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: focused
                      ? AppColors.textPrimary
                      : const Color(0x26FFFFFF),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: context.s(18),
                  color: focused
                      ? AppColors.background
                      : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "Clear all" text button next to the Recent searches label.
class _ClearAllButton extends StatelessWidget {
  const _ClearAllButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onTap: onTap,
      scale: 1.05,
      scrollAlignment: null,
      semanticLabel: 'Clear recent searches',
      builder: (context, focused) => AnimatedContainer(
        duration: Motion.quick,
        padding: EdgeInsets.symmetric(
          horizontal: context.s(14),
          vertical: context.s(4),
        ),
        decoration: BoxDecoration(
          color: focused ? AppColors.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(context.s(Radii.pill)),
        ),
        child: Text(
          'Clear all',
          style: AppText.caption.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: focused ? AppColors.background : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
