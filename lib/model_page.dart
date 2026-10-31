import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_page.dart';
import 'app_theme.dart';
import 'favorite_models_store.dart';
import 'offline_listing_cache.dart';
import 'offline_album_cache.dart';
import 'error_text.dart';
import 'models.dart';
import 'video_details_page.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/model_avatar.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

class ModelPage extends StatefulWidget {
  const ModelPage({super.key, required this.model});

  final ModelRef model;

  @override
  State<ModelPage> createState() => _ModelPageState();
}

void openModelPage(BuildContext context, ModelRef model) {
  Navigator.of(context).push<void>(
    adaptivePageRoute<void>(context, builder: (_) => ModelPage(model: model)),
  );
}

enum _Mode { videos, photos }

class _ModelPageState extends State<ModelPage> {
  static const int _maxPages = 300;
  static const int _maxAlbumPages = 60;

  _Mode _mode = _Mode.videos;

  final ScrollController _scrollController = ScrollController();

  final List<AlbumRef> _albums = <AlbumRef>[];
  final Set<String> _albumSeen = <String>{};
  int _albumNext = 1;
  bool _albumsLoading = true;
  bool _albumsRequestActive = false;
  bool _albumsFinishedLoading = false;
  Object? _albumsError;
  int _albumRun = 0;

  AlbumLoader? _soloLoader;
  final PhotoSelection _selection = PhotoSelection();

  final List<Video> _videos = <Video>[];
  final Set<String> _seen = <String>{};
  ModelProfile? _profile;
  int _nextPage = 1;
  bool _loading = true;
  bool _videosFinishedLoading = false;
  Object? _error;

  int _run = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadAll();
    _loadAlbums();
  }

  @override
  void dispose() {
    _run++;
    _albumRun++;
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _soloLoader
      ?..removeListener(_onSoloLoaderChanged)
      ..dispose();
    _selection.dispose();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    if (!mounted ||
        _albumsRequestActive ||
        _albumsFinishedLoading ||
        _albumNext > _maxAlbumPages) {
      return;
    }
    final run = ++_albumRun;
    final page = _albumNext;
    _albumsRequestActive = true;
    if (!_albumsLoading || _albumsError != null) {
      setState(() {
        _albumsLoading = true;
        _albumsError = null;
      });
    }

    final cacheKey = _offlineAlbumKey(page);
    final cached = OfflineAlbumCache.read(cacheKey);
    if (cached != null && cached.isNotEmpty && mounted && run == _albumRun) {
      setState(() {
        for (final album in cached) {
          if (_albumSeen.add(album.id)) _albums.add(album);
        }
        _albumsError = null;
        _albumsLoading = true;
      });
      _scheduleLoadIfViewportIsShort();
    }

    try {
      final result = await videoRepository.getModelAlbums(
        widget.model,
        page: page,
      );
      if (!mounted || run != _albumRun) return;
      OfflineAlbumCache.write(cacheKey, result);
      var added = 0;
      for (final album in result) {
        if (_albumSeen.add(album.id)) {
          _albums.add(album);
          added++;
        }
      }
      final finished =
          result.isEmpty ||
          (added == 0 && cached == null) ||
          page >= _maxAlbumPages;
      setState(() {
        _albumNext = page + 1;
        _albumsLoading = false;
        _albumsFinishedLoading = finished;
        _albumsError = null;
      });
      if (finished) _albumsFinished();
      _scheduleLoadIfViewportIsShort();
    } catch (error) {
      if (!mounted || run != _albumRun) return;
      setState(() {
        _albumsLoading = false;
        _albumsError = error;
      });
    } finally {
      if (run == _albumRun) _albumsRequestActive = false;
    }
  }

  void _albumsFinished() {
    if (!mounted) return;
    if (_albums.isEmpty && _mode == _Mode.photos && _albumsError == null) {
      setState(() => _mode = _Mode.videos);
    }
    if (_albums.length == 1 && _soloLoader == null) {
      _soloLoader = AlbumLoader(_albums.first)
        ..addListener(_onSoloLoaderChanged);
      if (_mode == _Mode.photos) _soloLoader!.load();
    }
  }

  void _onSoloLoaderChanged() => _scheduleLoadIfViewportIsShort();

  void _retryAlbums() {
    if (_albumsRequestActive || _albumsFinishedLoading) return;
    _loadAlbums();
  }

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == _Mode.photos) {
      _loadAlbums();
      _soloLoader?.load();
    } else {
      _selection.clear();
    }
  }

  void _openAlbum(AlbumRef album) {
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context,
        builder: (_) => AlbumPage(album: album, modelName: widget.model.name),
      ),
    );
  }

  bool get _hasPhotos => _albums.isNotEmpty || _albumsError != null;

  String _offlineKey(int page) {
    var hash = 0x811c9dc5;
    for (final unit in widget.model.url.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 'model_${hash.toRadixString(16)}_$page';
  }

  String _offlineAlbumKey(int page) {
    var hash = 0x811c9dc5;
    for (final unit in widget.model.url.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 'model_albums_${hash.toRadixString(16)}_$page';
  }

  Future<void> _loadAll() async {
    if (!mounted || _loading == false && _videosFinishedLoading) return;
    if (_runInFlight) return;
    final run = ++_run;
    final page = _nextPage;
    _runInFlight = true;
    if (!_loading || _error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final cacheKey = _offlineKey(page);
    final cached = OfflineListingCache.read(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      var cachedAdded = 0;
      for (final video in cached) {
        if (_seen.add(video.id)) {
          _videos.add(video);
          cachedAdded++;
        }
      }
      if (cachedAdded > 0 && mounted && run == _run) {
        setState(() => _error = null);
        _scheduleLoadIfViewportIsShort();
      }
    }

    try {
      final result = await videoRepository.getModelPage(
        widget.model,
        page: page,
      );
      if (!mounted || run != _run) return;
      var added = 0;
      for (final video in result.videos) {
        if (_seen.add(video.id)) {
          _videos.add(video);
          added++;
        }
      }
      OfflineListingCache.write(cacheKey, result.videos);
      if (result.profile?.imageUrl != null) {
        FavoriteModelsStore.instance.updateImage(
          widget.model.url,
          result.profile!.imageUrl,
        );
      }
      final finished =
          result.videos.isEmpty ||
          (added == 0 && cached == null) ||
          page >= _maxPages;
      setState(() {
        _profile ??= result.profile;
        _nextPage = page + 1;
        _loading = false;
        _videosFinishedLoading = finished;
        _error = null;
      });
      _scheduleLoadIfViewportIsShort();
    } catch (error) {
      if (!mounted || run != _run) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    } finally {
      if (run == _run) _runInFlight = false;
    }
  }

  bool _runInFlight = false;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 700) {
      _loadNextForVisibleMode();
    }
  }

  void _loadNextForVisibleMode() {
    if (_mode == _Mode.videos) {
      if (!_loading && !_videosFinishedLoading && _error == null) {
        _loadAll();
      }
      return;
    }
    if (_soloLoader != null) {
      final loader = _soloLoader!;
      if (!loader.loading && !loader.finished && loader.error == null) {
        loader.load();
      }
    } else if (!_albumsLoading &&
        !_albumsFinishedLoading &&
        _albumsError == null) {
      _loadAlbums();
    }
  }

  void _scheduleLoadIfViewportIsShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onScroll();
    });
  }

  void _retry() {
    if (_runInFlight || _videosFinishedLoading) return;
    _loadAll();
  }

  void _openVideo(Video video) {
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context,
        builder: (_) => VideoDetailsPage(video: video, queue: _videos),
      ),
    );
  }

  String get _countLabel {
    if (_mode == _Mode.photos) {
      final n = _albums.length;
      final base = '$n album${n == 1 ? '' : 's'}';
      return _albumsLoading ? '$base \u00b7 loading\u2026' : base;
    }
    final n = _videos.length;
    final base = '$n video${n == 1 ? '' : 's'}';
    return _loading ? '$base \u00b7 loading\u2026' : base;
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    final name = _profile?.name ?? widget.model.name;
    final firstLoad = _videos.isEmpty && _loading;
    final failedEmpty = _videos.isEmpty && _error != null;
    final finishedEmpty = _videos.isEmpty && !_loading && _error == null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: ListenableBuilder(
        listenable: _selection,
        builder: (context, child) => PopScope(
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.clear();
          },
          child: child!,
        ),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: Stack(
            children: [
              CustomScrollView(
                key: PageStorageKey<String>(
                  'model-scroll-${widget.model.url}',
                ),
                controller: _scrollController,
                physics: nativeScrollPhysics(context, alwaysScrollable: true),
                scrollCacheExtent: ScrollCacheExtent.pixels(
                  MediaQuery.sizeOf(context).height * 0.7,
                ),
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader(margin, name)),
                  if (_mode == _Mode.photos)
                    ..._photoSlivers(margin)
                  else ...[
                    if (firstLoad)
                      SliverSkeletonGrid(
                        count: 4,
                        padding: EdgeInsets.symmetric(horizontal: margin),
                      )
                    else if (failedEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: StatusView(
                          icon: describeError(_error!).icon,
                          title: describeError(_error!).title,
                          message: describeError(_error!).message,
                          actionLabel: 'Retry',
                          onAction: _retry,
                        ),
                      )
                    else if (finishedEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: StatusView(
                          icon: Icons.video_library_outlined,
                          title: 'No videos found',
                          message: 'This model has no videos yet.',
                        ),
                      )
                    else
                      SliverVideoGrid(
                        videos: _videos,
                        padding: EdgeInsets.symmetric(horizontal: margin),
                        onOpen: _openVideo,
                      ),
                    if (_error != null && _videos.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: margin,
                            vertical: Gaps.lg,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Couldn\u2019t load the rest of the videos.',
                                  style: AppText.body,
                                ),
                              ),
                              AppButton(
                                label: 'Retry',
                                icon: Icons.refresh_rounded,
                                style: AppButtonStyle.secondary,
                                onPressed: _retry,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_loading && _videos.isNotEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: Gaps.lg),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: SizedBox(height: Gaps.xl + context.safe.bottom),
                  ),
                ],
              ),
              if (_soloLoader != null && _mode == _Mode.photos)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: PhotoSelectionBar(
                    loader: _soloLoader!,
                    selection: _selection,
                    modelName: widget.model.name,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _photoSlivers(double margin) {
    final padding = EdgeInsets.symmetric(horizontal: margin);

    if (_albums.isEmpty) {
      if (_albumsError != null) {
        final friendly = describeError(_albumsError!, subject: 'photos');
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: StatusView(
              icon: friendly.icon,
              title: friendly.title,
              message: friendly.message,
              actionLabel: 'Retry',
              onAction: _retryAlbums,
            ),
          ),
        ];
      }
      if (_albumsLoading) {
        return [SliverSkeletonGrid(count: 4, padding: padding)];
      }
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: Icons.photo_library_outlined,
            title: 'No photos',
            message: 'This model has no photo albums.',
          ),
        ),
      ];
    }

    final solo = _soloLoader;
    if (!_albumsLoading && _albums.length == 1 && solo != null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: padding.add(const EdgeInsets.only(bottom: Gaps.md)),
            child: ListenableBuilder(
              listenable: solo,
              builder: (context, _) => Row(
                children: [
                  Expanded(
                    child: Text(
                      _albums.first.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title,
                    ),
                  ),
                  const SizedBox(width: Gaps.md),
                  Text(
                    solo.countLabel,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: padding.add(const EdgeInsets.only(bottom: Gaps.md)),
            child: AlbumToolbar(
              loader: solo,
              selection: _selection,
              modelName: widget.model.name,
            ),
          ),
        ),
        PhotoGridSliver(
          loader: solo,
          selection: _selection,
          modelName: widget.model.name,
          padding: padding,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 72)),
      ];
    }

    return [
      SliverPadding(
        padding: padding,
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: Gaps.md,
            mainAxisSpacing: Gaps.lg,
            childAspectRatio: 0.62,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => AlbumCard(
              key: ValueKey<String>(_albums[index].id),
              album: _albums[index],
              onTap: () => _openAlbum(_albums[index]),
            ),
            childCount: _albums.length,
          ),
        ),
      ),
      if (_albumsError != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: padding.add(const EdgeInsets.only(top: Gaps.lg)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Couldn\u2019t load all the albums.',
                    style: AppText.body,
                  ),
                ),
                AppButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  style: AppButtonStyle.secondary,
                  onPressed: _retryAlbums,
                ),
              ],
            ),
          ),
        ),
      if (_albumsLoading && _albums.isNotEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Gaps.lg),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildHeader(double margin, String name) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        margin,
        context.safe.top + Gaps.md,
        margin,
        Gaps.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageBackButton(),
          const SizedBox(height: Gaps.lg),
          Row(
            children: [
              ModelAvatar(
                name: name,
                imageUrl: _profile?.imageUrl ?? widget.model.imageUrl,
                pageUrl: widget.model.url,
                size: 84,
              ),
              const SizedBox(width: Gaps.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _countLabel,
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              ListenableBuilder(
                listenable: FavoriteModelsStore.instance,
                builder: (context, _) {
                  final favorites = FavoriteModelsStore.instance;
                  final isFavorite = favorites.isFavorite(widget.model.url);
                  return Pressable(
                    semanticLabel: isFavorite
                        ? 'Remove from favourite models'
                        : 'Add to favourite models',
                    haptic: Haptic.medium,
                    pressedScale: 0.85,
                    onTap: () {
                      favorites.toggle(
                        ModelRef(
                          name: name,
                          url: widget.model.url,
                          imageUrl: _profile?.imageUrl ?? widget.model.imageUrl,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Icon(
                        isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 30,
                        color: isFavorite
                            ? AppColors.star
                            : AppColors.textSecondary,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          if (_hasPhotos) ...[
            const SizedBox(height: Gaps.lg),
            _ModeSwitch(mode: _mode, onChanged: _setMode),
          ],
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final _Mode mode;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget segment(_Mode value, IconData icon, String label) {
      final selected = mode == value;
      return Expanded(
        child: Pressable(
          semanticLabel: selected ? '$label, selected' : label,
          haptic: Haptic.selection,
          pressedScale: 0.97,
          onTap: () => onChanged(value),
          child: AnimatedContainer(
            duration: Motion.normal,
            curve: Motion.curve,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppColors.accentStrong : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? Colors.white : AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppText.label.copyWith(
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          segment(_Mode.videos, Icons.play_circle_outline_rounded, 'Videos'),
          segment(_Mode.photos, Icons.photo_library_outlined, 'Photos'),
        ],
      ),
    );
  }
}
