import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoIcons, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app_theme.dart';
import '../error_text.dart';
import '../models.dart';
import '../request_cache.dart';
import '../search_history.dart';
import '../touch.dart';
import '../video_repository.dart';
import 'all_albums_view.dart';
import 'ios_sheets.dart';
import 'app_button.dart';
import 'model_row.dart';
import 'state_views.dart';
import 'video_grid.dart';

enum SearchScope { videos, people, albums }

enum SearchSort {
  relevant(null, 'Relevant'),
  newest('post_date', 'Newest'),
  longest('duration', 'Longest');

  const SearchSort(this.param, this.label);

  final String? param;
  final String label;
}

class SearchOverlay extends StatefulWidget {
  const SearchOverlay({
    super.key,
    required this.onClose,
    required this.onOpen,
    this.bottomInset = 0,
  });

  final double bottomInset;

  final VoidCallback onClose;

  final void Function(Video video, List<Video> queue) onOpen;

  @override
  State<SearchOverlay> createState() => SearchOverlayState();
}

class SearchOverlayState extends State<SearchOverlay> {
  static const Duration _debounce = Duration(milliseconds: 450);
  static const int _pageSize = 12;

  static const int _minLength = 2;
  static const int _maxEmptyPages = 3;

  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _fieldNode = FocusNode(debugLabel: 'Search field');

  Timer? _debounceTimer;
  final List<Video> _videos = <Video>[];
  String _query = '';
  bool _hasText = false;
  bool _awaiting = false;
  int _page = 0;
  int _generation = 0;
  int _emptyPages = 0;
  bool _loading = false;
  bool _hasMore = false;
  FriendlyError? _error;

  SearchScope _scope = SearchScope.videos;
  SearchSort _sort = SearchSort.relevant;

  PeopleSearchResult? _people;
  bool _peopleLoading = false;
  FriendlyError? _peopleError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (mounted) _fieldNode.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _generation++;
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _text.dispose();
    _fieldNode.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    if (_scope == SearchScope.albums) return;
    final value = SearchHistory.normalize(raw);
    _debounceTimer?.cancel();

    if (value.isEmpty) {
      _clearResults();
      return;
    }
    if (value == _query && !_awaiting) return;
    if (value.length < _minLength) {
      _generation++;
      setState(() {
        _hasText = true;
        _awaiting = true;
        _query = '';
        _videos.clear();
        _people = null;
        _peopleLoading = false;
        _loading = false;
        _hasMore = false;
        _error = null;
      });
      return;
    }

    if (!_hasText || !_awaiting) {
      setState(() {
        _hasText = true;
        _awaiting = true;
      });
    }
    _debounceTimer = Timer(_debounce, () => _runSearch(value));
  }

  void _clearResults() {
    _generation++;
    setState(() {
      _query = '';
      _hasText = false;
      _awaiting = false;
      _videos.clear();
      _people = null;
      _peopleLoading = false;
      _peopleError = null;
      _page = 0;
      _emptyPages = 0;
      _loading = false;
      _hasMore = false;
      _error = null;
    });
  }

  void _clearField() {
    _text.clear();
    _debounceTimer?.cancel();
    _clearResults();
    _fieldNode.requestFocus();
  }

  void _runSearch(String value) {
    if (!mounted || _scope == SearchScope.albums) return;
    _query = value;
    _awaiting = false;
    if (_scope == SearchScope.people) {
      _loadPeople();
    } else {
      _loadPage(reset: true);
    }
  }

  void _setScope(SearchScope scope) {
    if (scope == _scope) return;
    _debounceTimer?.cancel();
    if (scope == SearchScope.albums) {
      _generation++;
      _fieldNode.unfocus();
    }
    setState(() => _scope = scope);
    _searchAgain();
  }

  void _setSort(SearchSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    _searchAgain();
  }

  void _searchAgain() {
    if (_scope == SearchScope.albums) return;
    final value = SearchHistory.normalize(_text.text);
    if (value.length >= _minLength) {
      _debounceTimer?.cancel();
      _runSearch(value);
    }
  }

  Future<void> _loadPeople() async {
    final generation = ++_generation;
    final text = _query;
    setState(() {
      _videos.clear();
      _loading = false;
      _hasMore = false;
      _error = null;
      _people = null;
      _peopleError = null;
      _peopleLoading = true;
    });
    try {
      final result = await peopleCache.fetch(
        'people|${text.toLowerCase()}',
        () => videoRepository.searchPeople(text),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _people = result;
        _peopleLoading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _peopleLoading = false;
        _peopleError = describeError(error, subject: 'search results');
      });
    }
  }

  void _submit() {
    _debounceTimer?.cancel();
    final value = SearchHistory.normalize(_text.text);
    if (value.isEmpty) return;
    SearchHistory.instance.add(value);
    _fieldNode.unfocus();
    if ((_loading || _peopleLoading) && value == _query) return;
    setState(() => _hasText = true);
    _runSearch(value);
  }

  void _useRecent(String term) {
    _debounceTimer?.cancel();
    _text.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    SearchHistory.instance.add(term);
    _fieldNode.unfocus();
    setState(() => _hasText = true);
    _runSearch(term);
  }

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
      final searchText = _query;
      final pageIndex = _page;
      final result = await listingCache.fetch(
        'search|${searchText.toLowerCase()}|${_sort.name}|$pageIndex',
        () => videoRepository.searchVideos(
          query: searchText,
          page: pageIndex,
          pageSize: _pageSize,
          sortBy: _sort.param,
        ),
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
        _error = describeError(error, subject: 'search results');
      });
    }
  }

  void _openVideo(Video video) {
    SearchHistory.instance.add(_query);
    _fieldNode.unfocus();
    widget.onOpen(video, List<Video>.of(_videos));
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              margin,
              context.safe.top + Gaps.sm,
              margin,
              Gaps.sm,
            ),
            child: _buildSearchBar(),
          ),
          _buildFilters(margin),
          Expanded(child: _buildBody(margin)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final dark = AppColors.palette.brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: _fieldNode,
            builder: (context, _) {
              // UISearchBar: rounded tertiary-fill capsule, no outline, a
              // leading magnifier and a trailing round clear button.
              return AnimatedContainer(
                duration: Motion.normal,
                height: 40,
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0x3D767680)
                      : const Color(0x1F767680),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 12, right: 6),
                      child: Icon(
                        CupertinoIcons.search,
                        size: 18,
                        color: AppColors.textTertiary,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        focusNode: _fieldNode,
                        autofocus: false,
                        enabled: _scope != SearchScope.albums,
                        maxLines: 1,
                        textAlignVertical: TextAlignVertical.center,
                        textInputAction: TextInputAction.search,
                        keyboardType: TextInputType.text,
                        keyboardAppearance: AppColors.palette.brightness,
                        autocorrect: false,
                        enableSuggestions: true,
                        textCapitalization: TextCapitalization.none,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        onChanged: _onChanged,
                        onSubmitted: (_) => _submit(),
                        cursorColor: AppColors.accent,
                        cursorHeight: 20,
                        style: TextStyle(
                          fontSize: 17,
                          letterSpacing: -0.41,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          fillColor: Colors.transparent,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          hintText: switch (_scope) {
                            SearchScope.people => 'Search models',
                            SearchScope.albums => 'Albums',
                            SearchScope.videos => 'Search videos',
                          },
                          hintStyle: TextStyle(
                            fontSize: 17,
                            letterSpacing: -0.41,
                            color: AppColors.textTertiary,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    ListenableBuilder(
                      listenable: _text,
                      builder: (context, _) => AnimatedSwitcher(
                        duration: Motion.quick,
                        child: _text.text.isEmpty
                            ? const SizedBox(width: 12)
                            : Pressable(
                                key: const ValueKey<String>('clear'),
                                semanticLabel: 'Clear text',
                                haptic: Haptic.selection,
                                pressedScale: 0.85,
                                onTap: _clearField,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Icon(
                                    CupertinoIcons.xmark_circle_fill,
                                    size: 18,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(width: Gaps.md),
        Pressable(
          semanticLabel: 'Close search',
          haptic: Haptic.selection,
          pressedScale: 1,
          pressedOpacity: 0.4,
          onTap: widget.onClose,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontSize: 17,
                letterSpacing: -0.41,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickSort() async {
    final picked = await showActionSheet<SearchSort>(
      context,
      title: 'Sort Results',
      actions: [
        for (final sort in SearchSort.values)
          SheetAction<SearchSort>(
            label: sort == _sort ? '\u2713  ${sort.label}' : sort.label,
            value: sort,
            isDefault: sort == _sort,
          ),
      ],
    );
    if (picked != null) _setSort(picked);
  }

  /// Native scope bar (UISegmentedControl) plus a "Sort" menu button.
  Widget _buildFilters(double margin) {
    final dark = AppColors.palette.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(margin, Gaps.xs, margin, Gaps.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoSlidingSegmentedControl<SearchScope>(
            groupValue: _scope,
            backgroundColor:
                dark ? const Color(0x3D767680) : const Color(0x1F767680),
            thumbColor: dark ? const Color(0xFF636366) : Colors.white,
            padding: const EdgeInsets.all(2),
            children: <SearchScope, Widget>{
              for (final (scope, label) in const <(SearchScope, String)>[
                (SearchScope.videos, 'Videos'),
                (SearchScope.people, 'Models'),
                (SearchScope.albums, 'Albums'),
              ])
                scope: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      letterSpacing: -0.08,
                      fontWeight: scope == _scope
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
            },
            onValueChanged: (next) {
              if (next == null) return;
              Haptics.play(Haptic.selection);
              _setScope(next);
            },
          ),
          AnimatedSize(
            duration: Motion.normal,
            curve: Motion.curve,
            alignment: Alignment.topCenter,
            child: _scope == SearchScope.videos
                ? Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Pressable(
                      semanticLabel: 'Sort results',
                      pressedScale: 1,
                      pressedOpacity: 0.4,
                      haptic: Haptic.selection,
                      onTap: _pickSort,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.arrow_up_arrow_down,
                              size: 13,
                              color: AppColors.accent,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              _sort.label,
                              style: const TextStyle(
                                fontSize: 15,
                                letterSpacing: -0.24,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildPeopleBody(double margin) {
    final typed = SearchHistory.normalize(_text.text);
    if (_awaiting || typed.length < _minLength) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: margin, vertical: Gaps.xl),
        child: Text(
          typed.isEmpty
              ? 'Type a model name.'
              : 'Keep typing\u2026 (at least $_minLength letters)',
          style: AppText.body,
        ),
      );
    }
    final error = _peopleError;
    if (error != null) {
      return StatusView(
        icon: error.icon,
        title: error.title,
        message: error.message,
        actionLabel: 'Retry',
        onAction: _loadPeople,
      );
    }
    final people = _people;
    if (_peopleLoading || people == null) {
      return const Center(child: Spinner());
    }
    if (people.isEmpty) {
      return const StatusView(
        icon: CupertinoIcons.search,
        title: 'No models found',
        message: 'Try the exact model name, for example \u201cPlaywithanny\u201d.',
      );
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        if (people.models.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(margin, Gaps.sm, margin, Gaps.xs),
              child: Text(
                'Models \u00b7 ${people.models.length}',
                style: AppText.label.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => ModelRow(
                  key: ValueKey<String>(people.models[index].url),
                  model: people.models[index],
                ),
                childCount: people.models.length,
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: SizedBox(height: Gaps.xl + widget.bottomInset),
        ),
      ],
    );
  }

  Widget _buildBody(double margin) {
    if (_scope == SearchScope.albums) {
      return AllAlbumsView(
        key: const ValueKey<String>('all-albums'),
        bottomInset: widget.bottomInset,
      );
    }
    if (!_hasText) return _buildRecents(margin);
    if (_scope == SearchScope.people) return _buildPeopleBody(margin);

    final gridPadding = EdgeInsets.fromLTRB(
      margin,
      Gaps.xs,
      margin,
      Gaps.xl + widget.bottomInset,
    );

    final waiting = _awaiting || (_loading && _videos.isEmpty);
    final error = _error;
    final typed = SearchHistory.normalize(_text.text).toLowerCase();
    final suggestions = typed.isEmpty
        ? const <String>[]
        : SearchHistory.instance.items
            .where((term) => term.toLowerCase().startsWith(typed) &&
                term.toLowerCase() != typed)
            .take(5)
            .toList();

    final List<Widget> slivers;
    if (waiting && _videos.isEmpty && (suggestions.isNotEmpty || typed.length < _minLength)) {
      slivers = [
        SliverList(
          delegate: SliverChildListDelegate([
            for (final term in suggestions)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: margin),
                child: _RecentRow(
                  term: term,
                  onSelect: () => _useRecent(term),
                  onDelete: () => SearchHistory.instance.remove(term),
                ),
              ),
            if (suggestions.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: margin, vertical: Gaps.xl),
                child: Text(
                  'Keep typing\u2026 (at least $_minLength letters)',
                  style: AppText.body,
                ),
              ),
          ]),
        ),
      ];
    } else if (waiting && _videos.isEmpty) {
      slivers = [SliverSkeletonGrid(padding: gridPadding)];
    } else if (_videos.isEmpty && error != null) {
      slivers = [
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
    } else if (_videos.isEmpty) {
      slivers = [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: CupertinoIcons.search,
            title: 'No results found',
            message: 'Check the spelling or try a different keyword.',
          ),
        ),
      ];
    } else {
      slivers = [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(margin, Gaps.xs, margin, Gaps.sm),
            child: Text(
              'Results for \u201c$_query\u201d',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.body,
            ),
          ),
        ),
        SliverVideoGrid(
          videos: _videos,
          padding: gridPadding,
          onOpen: _openVideo,
        ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: Gaps.xl),
              child: Spinner(),
            ),
          ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gaps.xl),
              child: Center(
                child: AppButton(
                  label: 'Couldn\u2019t load more \u2013 Retry',
                  icon: CupertinoIcons.refresh,
                  style: AppButtonStyle.secondary,
                  onPressed: _loadPage,
                ),
              ),
            ),
          ),
      ];
    }

    return CustomScrollView(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      scrollCacheExtent: ScrollCacheExtent.pixels(
        MediaQuery.sizeOf(context).height,
      ),
      slivers: slivers,
    );
  }

  Widget _buildRecents(double margin) {
    return ListenableBuilder(
      listenable: SearchHistory.instance,
      builder: (context, _) {
        final items = SearchHistory.instance.items;
        if (items.isEmpty) {
          return StatusView(
            icon: CupertinoIcons.search,
            title: _scope == SearchScope.people
                ? 'Search for models'
                : 'Search for videos',
            message: 'Results appear as you type.',
          );
        }
        return ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            margin,
            Gaps.sm,
            margin,
            widget.bottomInset,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent Searches',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.38,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Pressable(
                  semanticLabel: 'Clear recent searches',
                  haptic: Haptic.selection,
                  pressedScale: 1,
                  pressedOpacity: 0.4,
                  onTap: SearchHistory.instance.clear,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Clear',
                      style: TextStyle(
                        fontSize: 17,
                        letterSpacing: -0.41,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            for (final term in items)
              _RecentRow(
                key: ValueKey<String>(term),
                term: term,
                onSelect: () => _useRecent(term),
                onDelete: () => SearchHistory.instance.remove(term),
              ),
          ],
        );
      },
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    super.key,
    required this.term,
    required this.onSelect,
    required this.onDelete,
  });

  final String term;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Swipe left to delete, exactly like a UITableView row with a trailing
    // destructive swipe action; hairline separator inset past the icon.
    return Dismissible(
      key: ValueKey<String>('recent-$term'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const <DismissDirection, double>{
        DismissDirection.endToStart: 0.35,
      },
      onUpdate: (details) {
        if (details.reached && !details.previousReached) {
          Haptics.play(Haptic.medium);
        }
      },
      onDismissed: (_) => onDelete(),
      background: const SizedBox.shrink(),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.error,
        child: const Icon(CupertinoIcons.delete, size: 22, color: Colors.white),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: AppColors.background),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Pressable(
              semanticLabel: term,
              haptic: Haptic.selection,
              pressedScale: 1,
              pressedOpacity: 0.5,
              onTap: onSelect,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      CupertinoIcons.clock,
                      size: 20,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: Gaps.md),
                    Expanded(
                      child: Text(
                        term,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          letterSpacing: -0.41,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      CupertinoIcons.arrow_up_left,
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Container(height: 0.5, color: AppColors.outline),
            ),
          ],
        ),
      ),
    );
  }
}
