import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_page.dart';
import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'video_details_page.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

/// All the videos of one model / channel.
///
/// The first page is `.../models/slug/videos/`, the next ones `.../videos/2/`,
/// `.../videos/3/`, and so on. Pages are fetched one after another until the
/// last video, and the total at the top grows as they arrive.
class ModelPage extends StatefulWidget {
  const ModelPage({super.key, required this.model});

  final ModelRef model;

  @override
  State<ModelPage> createState() => _ModelPageState();
}

enum _Mode { videos, photos }

class _ModelPageState extends State<ModelPage> {
  /// Safety stop so a misbehaving site can never loop forever.
  static const int _maxPages = 300;
  static const int _maxAlbumPages = 60;

  _Mode _mode = _Mode.videos;

  // Photo albums (loaded in the background next to the videos).
  final List<AlbumRef> _albums = <AlbumRef>[];
  final Set<String> _albumSeen = <String>{};
  int _albumNext = 1;
  bool _albumsLoading = true;
  Object? _albumsError;
  int _albumRun = 0;

  /// A model with exactly one album shows its photos straight away.
  AlbumLoader? _soloLoader;

  final List<Video> _videos = <Video>[];
  final Set<String> _seen = <String>{};
  ModelProfile? _profile;
  int _nextPage = 1;
  bool _loading = true;
  Object? _error;

  /// Bumped on dispose / retry so an old loop stops quietly.
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

  /// All albums are known: a single album opens its photos directly.
  void _albumsFinished() {
    if (!mounted) return;
    if (_albums.isEmpty && _mode == _Mode.photos && _albumsError == null) {
      setState(() => _mode = _Mode.videos); // Nothing to show: back to videos.
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
    if (mode == _Mode.photos) _soloLoader?.load();
  }

  void _openAlbum(AlbumRef album) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => AlbumPage(album: album)),
    );
  }

  /// The switch only appears once the model is known to have albums (some
  /// models have none), or when loading them failed and can be retried.
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
      // An empty page (or one with nothing new) is the end of the list.
      final last = added == 0;
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
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: CustomScrollView(
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
      ),
    );
  }

  /// Slivers of the "Photos" tab: albums as a grid; a model with exactly one
  /// album shows that album's photos straight away.
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
        PhotoGridSliver(loader: solo, padding: padding),
      ];
    }

    final origin = Uri.tryParse(widget.model.url)?.origin;
    final headers =
        origin == null ? null : <String, String>{'Referer': '$origin/'};
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
            (context, index) => _AlbumCard(
              key: ValueKey<String>(_albums[index].id),
              album: _albums[index],
              headers: headers,
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
              _Avatar(name: name, imageUrl: _profile?.imageUrl, pageUrl: widget.model.url),
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
                    // Total number of videos (grows while the pages arrive).
                    Text(
                      _countLabel,
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
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

/// Videos | Photos switch under the model's name.
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

/// An album: its (portrait) preview picture and title.
class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    super.key,
    required this.album,
    required this.headers,
    required this.onTap,
  });

  final AlbumRef album;
  final Map<String, String>? headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final thumb = album.thumbnailUrl;
    final placeholder = Container(
      color: AppColors.surfaceHigh,
      alignment: Alignment.center,
      child: Icon(
        Icons.photo_library_outlined,
        color: AppColors.textTertiary,
        size: 32,
      ),
    );
    return Pressable(
      semanticLabel: 'Album ${album.title}',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: SizedBox.expand(
                child: thumb == null
                    ? placeholder
                    : Image.network(
                        thumb,
                        fit: BoxFit.cover,
                        headers: headers,
                        cacheWidth: (200 * dpr).round(),
                        errorBuilder: (context, error, stack) => placeholder,
                        loadingBuilder: (context, child, progress) =>
                            progress == null ? child : placeholder,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.cardTitle,
          ),
        ],
      ),
    );
  }
}

/// Round photo of the model. Some models have no photo: their initial is
/// shown instead.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.imageUrl, required this.pageUrl});

  static const double size = 84;

  final String name;
  final String? imageUrl;
  final String pageUrl;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final placeholder = Container(
      color: AppColors.accentStrong,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: AppText.display.copyWith(fontSize: 34, color: Colors.white),
      ),
    );

    final url = imageUrl;
    final Widget content;
    if (url == null || url.isEmpty) {
      content = placeholder;
    } else {
      final origin = Uri.tryParse(pageUrl)?.origin;
      content = Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        // Some CDNs refuse hot-linked images without a Referer.
        headers: origin == null ? null : <String, String>{'Referer': '$origin/'},
        errorBuilder: (context, error, stackTrace) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.outline, width: 2),
      ),
      child: ClipOval(child: content),
    );
  }
}
