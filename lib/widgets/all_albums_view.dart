import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../album_page.dart';
import '../app_theme.dart';
import '../error_text.dart';
import '../models.dart';
import '../request_cache.dart';
import '../video_repository.dart';
import 'app_button.dart';
import 'state_views.dart';

class AllAlbumsView extends StatefulWidget {
  const AllAlbumsView({super.key, this.bottomInset = 0});

  final double bottomInset;

  @override
  State<AllAlbumsView> createState() => _AllAlbumsViewState();
}

class _AllAlbumsViewState extends State<AllAlbumsView> {
  static const int _maxEmptyPages = 2;

  final ScrollController _scroll = ScrollController();
  final List<AlbumRef> _albums = <AlbumRef>[];
  final Set<String> _seen = <String>{};

  int _page = 1;
  int _emptyPages = 0;
  int _generation = 0;
  bool _loading = false;
  bool _hasMore = true;
  FriendlyError? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _load(reset: true);
  }

  @override
  void dispose() {
    _generation++;
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || !_hasMore || _error != null) return;
    if (_scroll.position.maxScrollExtent - _scroll.position.pixels < 900) {
      _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _albums.clear();
        _seen.clear();
        _page = 1;
        _emptyPages = 0;
        _hasMore = true;
      }
    });

    try {
      final page = _page;
      final result = await albumsCache.fetch(
        'albums|all|$page',
        () => videoRepository.getAllAlbums(page: page),
      );
      if (!mounted || generation != _generation) return;

      final fresh = <AlbumRef>[
        for (final album in result)
          if (_seen.add(album.id)) album,
      ];
      setState(() {
        _albums.addAll(fresh);
        _page = page + 1;
        _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
        _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
        _loading = false;
      });

      if (_hasMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _loading || !_hasMore || !_scroll.hasClients) return;
          if (_scroll.position.maxScrollExtent < 200) _load();
        });
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _hasMore = false;
        _error = describeError(error, subject: 'albums');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final error = _error;

    if (_albums.isEmpty && _loading) {
      return const Center(child: Spinner());
    }
    if (_albums.isEmpty && error != null) {
      return StatusView(
        icon: error.icon,
        title: error.title,
        message: error.message,
        actionLabel: 'Retry',
        onAction: () => _load(reset: true),
      );
    }
    if (_albums.isEmpty) {
      return StatusView(
        icon: Icons.photo_library_outlined,
        title: 'No albums found',
        message: 'There is nothing to show right now.',
        actionLabel: 'Refresh',
        onAction: () => _load(reset: true),
      );
    }

    return CustomScrollView(
      controller: _scroll,
      scrollCacheExtent: ScrollCacheExtent.pixels(
        MediaQuery.sizeOf(context).height,
      ),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(margin, Gaps.sm, margin, 0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: Gaps.md,
              mainAxisSpacing: Gaps.lg,
              childAspectRatio: 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final album = _albums[index];
                return AlbumCard(
                  key: ValueKey<String>(album.id),
                  album: album,
                  subtitle: album.modelName,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => AlbumPage(
                        album: album,
                        modelName: album.modelName,
                      ),
                    ),
                  ),
                );
              },
              childCount: _albums.length,
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: Gaps.lg),
              child: Spinner(),
            ),
          ),
        if (error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: Gaps.lg),
              child: Center(
                child: AppButton(
                  label: 'Couldn\u2019t load more \u2013 Retry',
                  icon: Icons.refresh_rounded,
                  style: AppButtonStyle.secondary,
                  onPressed: _load,
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: Gaps.xl + widget.bottomInset),
        ),
      ],
    );
  }
}
