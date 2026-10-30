import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_page.dart';
import 'app_theme.dart';
import 'favorite_models_store.dart';
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
    MaterialPageRoute<void>(builder: (_) => ModelPage(model: model)),
  );
}

enum _Mode { videos, photos }

class _ModelPageState extends State<ModelPage> {
  static const int _maxPages = 300;
  static const int _maxAlbumPages = 60;

  _Mode _mode = _Mode.videos;

  final List<AlbumRef> _albums = <AlbumRef>[];
  final Set<String> _albumSeen = <String>{};
  int _albumNext = 1;
  bool _albumsLoading = true;
  Object? _albumsError;
  int _albumRun = 0;

  AlbumLoader? _soloLoader;
  final PhotoSelection _selection = PhotoSelection();

  final List<Video> _videos = <Video>[];
  final Set<String> _seen = <String>{};
  ModelProfile? _profile;
  int _nextPage = 1;
  bool _loading = true;
  Object? _error;

  int _run = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadAlbums();
  }

  @override
  void dispose() {
    _run++;
    _albumRun++;
    _soloLoader?.dispose();
    _selection.dispose();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    final run = ++_albumRun;
    while (mounted && run == _albumRun && _albumNext <= _maxAlbumPages) {
      final page = _albumNext;
      final List<AlbumRef> result;
      try {
        result = await videoRepository.getModelAlbums(widget.model, page: page);
      } catch (error) {
        if (!mounted || run != _albumRun) return;
        setState(() {
          _albumsLoading = false;
          _albumsError = error;
        });
        return;
      }
      if (!mounted || run != _albumRun) return;

      var added = 0;
      for (final album in result) {
        if (_albumSeen.add(album.id)) {
          _albums.add(album);
          added++;
        }
      }
      setState(() {
        _albumNext = page + 1;
        if (added == 0) _albumsLoading = false;
      });
      if (added == 0) {
        _albumsFinished();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (mounted && run == _albumRun) {
      setState(() => _albumsLoading = false);
      _albumsFinished();
    }
  }

  void _albumsFinished() {
    if (!mounted) return;
    if (_albums.isEmpty && _mode == _Mode.photos && _albumsError == null) {
      setState(() => _mode = _Mode.videos);
    }
    if (_albums.length == 1 && _soloLoader == null) {
      _soloLoader = AlbumLoader(_albums.first);
      if (_mode == _Mode.photos) _soloLoader!.load();
    }
  }

  void _retryAlbums() {
    setState(() {
      _albumsLoading = true;
      _albumsError = null;
    });
    _loadAlbums();
  }

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == _Mode.photos) {
      _soloLoader?.load();
    } else {
      _selection.clear();
    }
  }

  void _openAlbum(AlbumRef album) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPage(album: album, modelName: widget.model.name),
      ),
    );
  }

  bool get _hasPhotos => _albums.isNotEmpty || _albumsError != null;

  Future<void> _loadAll() async {
    final run = ++_run;
    while (mounted && run == _run && _nextPage <= _maxPages) {
      final page = _nextPage;
      final ModelPageResult result;
      try {
        result = await videoRepository.getModelPage(widget.model, page: page);
      } catch (error) {
        if (!mounted || run != _run) return;
        setState(() {
          _loading = false;
          _error = error;
        });
        return;
      }
      if (!mounted || run != _run) return;

      var added = 0;
      for (final video in result.videos) {
        if (_seen.add(video.id)) {
          _videos.add(video);
          added++;
        }
      }
      final last = added == 0;
      if (result.profile?.imageUrl != null) {
        FavoriteModelsStore.instance
            .updateImage(widget.model.url, result.profile!.imageUrl);
      }
      setState(() {
        _profile ??= result.profile;
        _nextPage = page + 1;
        if (last) _loading = false;
      });
      if (last) return;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (mounted && run == _run) setState(() => _loading = false);
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadAll();
  }

  void _openVideo(Video video) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
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
                      favorites.toggle(ModelRef(
                        name: name,
                        url: widget.model.url,
                        imageUrl: _profile?.imageUrl ?? widget.model.imageUrl,
                      ));
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
                  size: 18,
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
