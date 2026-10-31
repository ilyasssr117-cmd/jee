import 'dart:async';

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
    return Row(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: _fieldNode,
            builder: (context, _) {
              final focused = _fieldNode.hasFocus;
              return AnimatedContainer(
                duration: Motion.normal,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(Radii.field),
                  border: Border.all(
                    color: focused
                        ? AppColors.accent.withValues(alpha: 0.8)
                        : AppColors.outline,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(
                        Icons.search_rounded,
                        size: 20,
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
                        keyboardAppearance: Brightness.dark,
                        onChanged: _onChanged,
                        onSubmitted: (_) => _submit(),
                        cursorColor: AppColors.accent,
                        style: AppText.title.copyWith(
                          fontWeight: FontWeight.w400,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: switch (_scope) {
                            SearchScope.people => 'Search models',
                            SearchScope.albums => 'All albums',
                            SearchScope.videos => 'Search videos',
                          },
                          hintStyle: AppText.title.copyWith(
                            fontWeight: FontWeight.w400,
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
                            ? const SizedBox(width: 10)
                            : Pressable(
                                key: const ValueKey<String>('clear'),
                                semanticLabel: 'Clear text',
                                haptic: Haptic.selection,
                                onTap: _clearField,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  child: Icon(
                                    Icons.cancel_rounded,
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
        const SizedBox(width: Gaps.sm),
        Pressable(
          semanticLabel: 'Close search',
          haptic: Haptic.selection,
          onTap: widget.onClose,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilters(double margin) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: margin, vertical: 6),
        children: [
          AppChip(
            label: 'Videos',
            selected: _scope == SearchScope.videos,
            onPressed: () => _setScope(SearchScope.videos),
          ),
          const SizedBox(width: Gaps.sm),
          AppChip(
            label: 'Models',
            selected: _scope == SearchScope.people,
            onPressed: () => _setScope(SearchScope.people),
          ),
          const SizedBox(width: Gaps.sm),
          AppChip(
            label: 'Albums',
            selected: _scope == SearchScope.albums,
            onPressed: () => _setScope(SearchScope.albums),
          ),
          if (_scope == SearchScope.videos) ...[
            const SizedBox(width: Gaps.md),
            Container(
              width: 1,
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: AppColors.outline,
            ),
            const SizedBox(width: Gaps.md),
            for (final sort in SearchSort.values) ...[
              AppChip(
                label: sort.label,
                selected: _sort == sort,
                onPressed: () => _setSort(sort),
              ),
              const SizedBox(width: Gaps.sm),
            ],
          ],
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
        icon: Icons.search_off_rounded,
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
                  icon: Icons.refresh_rounded,
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
            icon: Icons.search_rounded,
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
                    'Recent',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Pressable(
                  semanticLabel: 'Clear recent searches',
                  haptic: Haptic.selection,
                  onTap: SearchHistory.instance.clear,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Clear',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
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
    return Row(
      children: [
        Expanded(
          child: Pressable(
            semanticLabel: term,
            haptic: Haptic.selection,
            pressedScale: 0.98,
            onTap: onSelect,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: Gaps.md),
                  Expanded(
                    child: Text(
                      term,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title.copyWith(
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Pressable(
          semanticLabel: 'Remove $term',
          haptic: Haptic.light,
          pressedScale: 0.85,
          onTap: onDelete,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}
