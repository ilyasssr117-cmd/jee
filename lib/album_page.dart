import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/state_views.dart';

/// Loads every photo of one album, chunk after chunk, until the last one.
///
/// Chunk 1 is the album page, the next chunks are the site's "load more"
/// requests. The photos list grows while the chunks arrive.
class AlbumLoader extends ChangeNotifier {
  AlbumLoader(this.album);

  /// Safety stop so a misbehaving site can never loop forever.
  static const int _maxChunks = 400;

  final AlbumRef album;
  final List<AlbumPhoto> photos = <AlbumPhoto>[];
  final Set<String> _seen = <String>{};
  bool loading = false;
  bool finished = false;
  Object? error;

  int _next = 1;
  int _run = 0;
  bool _disposed = false;

  /// Some image servers refuse pictures requested without a Referer.
  Map<String, String>? get imageHeaders {
    final origin = Uri.tryParse(album.url)?.origin;
    return origin == null ? null : <String, String>{'Referer': '$origin/'};
  }

  /// Starts (or, after an error, resumes) loading. Safe to call repeatedly.
  Future<void> load() async {
    if (loading || finished || _disposed) return;
    final run = ++_run;
    loading = true;
    error = null;
    notifyListeners();

    while (!_disposed && run == _run && _next <= _maxChunks) {
      final List<AlbumPhoto> chunk;
      try {
        chunk = await videoRepository.getAlbumPhotos(album, chunk: _next);
      } catch (e) {
        if (_disposed || run != _run) return;
        loading = false;
        error = e;
        notifyListeners();
        return;
      }
      if (_disposed || run != _run) return;

      var added = 0;
      for (final photo in chunk) {
        if (_seen.add(photo.id)) {
          photos.add(photo);
          added++;
        }
      }
      _next++;
      if (added == 0) {
        // Nothing new: that was the last chunk.
        loading = false;
        finished = true;
        notifyListeners();
        return;
      }
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_disposed && run == _run) {
      loading = false;
      finished = true;
      notifyListeners();
    }
  }

  String get countLabel {
    final n = photos.length;
    final base = '$n photo${n == 1 ? '' : 's'}';
    return loading ? '$base \u00b7 loading\u2026' : base;
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    super.dispose();
  }
}

/// A whole album: back button, title, number of photos and the photo grid.
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, required this.album});

  final AlbumRef album;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  late final AlbumLoader _loader = AlbumLoader(widget.album);

  @override
  void initState() {
    super.initState();
    _loader.load();
  }

  @override
  void dispose() {
    _loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
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
                    Text(
                      widget.album.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline,
                    ),
                    const SizedBox(height: 4),
                    ListenableBuilder(
                      listenable: _loader,
                      builder: (context, _) => Text(
                        _loader.countLabel,
                        style: AppText.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PhotoGridSliver(
              loader: _loader,
              padding: EdgeInsets.symmetric(horizontal: margin),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: Gaps.xl + context.safe.bottom),
            ),
          ],
        ),
      ),
    );
  }
}

/// Photo grid (3 per row) for an [AlbumLoader]; tapping a photo opens the
/// full-screen viewer. Shows a skeleton while the first chunk loads and a
/// Retry row when a chunk fails.
class PhotoGridSliver extends StatelessWidget {
  const PhotoGridSliver({
    super.key,
    required this.loader,
    this.padding = EdgeInsets.zero,
  });

  final AlbumLoader loader;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: loader,
      builder: (context, _) {
        final photos = loader.photos;

        if (photos.isEmpty) {
          if (loader.error != null) {
            final friendly = describeError(loader.error!, subject: 'photos');
            return SliverFillRemaining(
              hasScrollBody: false,
              child: StatusView(
                icon: friendly.icon,
                title: friendly.title,
                message: friendly.message,
                actionLabel: 'Retry',
                onAction: loader.load,
              ),
            );
          }
          if (loader.finished) {
            return const SliverFillRemaining(
              hasScrollBody: false,
              child: StatusView(
                icon: Icons.photo_library_outlined,
                title: 'No photos',
                message: 'This album is empty.',
              ),
            );
          }
          return SliverPadding(
            padding: padding,
            sliver: SliverGrid(
              gridDelegate: _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, index) => const SkeletonPulse(
                  child: SkeletonBlock(radius: 6),
                ),
                childCount: 12,
              ),
            ),
          );
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _PhotoTile(
                    key: ValueKey<String>(photos[index].id),
                    photo: photos[index],
                    headers: loader.imageHeaders,
                    onTap: () => Navigator.of(context).push<void>(
                      PageRouteBuilder<void>(
                        opaque: true,
                        transitionDuration: const Duration(milliseconds: 180),
                        pageBuilder: (_, __, ___) =>
                            PhotoViewerPage(loader: loader, initialIndex: index),
                        transitionsBuilder: (_, animation, __, child) =>
                            FadeTransition(opacity: animation, child: child),
                      ),
                    ),
                  ),
                  childCount: photos.length,
                ),
              ),
            ),
            if (loader.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: padding.add(const EdgeInsets.only(top: Gaps.lg)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Couldn\u2019t load the rest of the photos.',
                          style: AppText.body,
                        ),
                      ),
                      AppButton(
                        label: 'Retry',
                        icon: Icons.refresh_rounded,
                        style: AppButtonStyle.secondary,
                        onPressed: loader.load,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static const SliverGridDelegate _gridDelegate =
      SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    crossAxisSpacing: 4,
    mainAxisSpacing: 4,
    childAspectRatio: 3 / 4,
  );
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.headers,
    required this.onTap,
  });

  final AlbumPhoto photo;
  final Map<String, String>? headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(
          color: AppColors.surfaceHigh,
          child: Image.network(
            photo.thumbUrl,
            fit: BoxFit.cover,
            headers: headers,
            // Thumbnails are small; never decode more than the tile needs.
            cacheWidth: (160 * dpr).round(),
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => Icon(
              Icons.broken_image_outlined,
              color: AppColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen photo viewer: swipe left / right between the photos, pinch or
/// double-tap to zoom, tap the cross to close. Photos that are still loading
/// are added to the end while the viewer is open.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.loader,
    required this.initialIndex,
  });

  final AlbumLoader loader;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: widget.loader,
          builder: (context, _) {
            final photos = widget.loader.photos;
            return Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pages,
                  // While zoomed in, dragging pans the picture instead.
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: photos.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) => _ZoomablePhoto(
                    key: ValueKey<String>(photos[index].id),
                    photo: photos[index],
                    headers: widget.loader.imageHeaders,
                    onZoomChanged: (zoomed) {
                      if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
                    },
                  ),
                ),
                Positioned(
                  top: context.safe.top + Gaps.md,
                  left: Gaps.lg,
                  right: Gaps.lg,
                  child: Row(
                    children: [
                      RoundIconButton(
                        icon: Icons.close_rounded,
                        iconSize: 20,
                        label: 'Close',
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      if (photos.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x8C000000),
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Text(
                            '${_index + 1} / ${photos.length}'
                            '${widget.loader.loading ? '+' : ''}',
                            style: AppText.label.copyWith(color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({
    super.key,
    required this.photo,
    required this.headers,
    required this.onZoomChanged,
  });

  final AlbumPhoto photo;
  final Map<String, String>? headers;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> {
  final TransformationController _controller = TransformationController();
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_report);
  }

  void _report() =>
      widget.onZoomChanged(_controller.value.getMaxScaleOnAxis() > 1.02);

  @override
  void dispose() {
    _controller.removeListener(_report);
    _controller.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_controller.value.getMaxScaleOnAxis() > 1.02) {
      _controller.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    final p = _doubleTapAt;
    // Column-major matrix: uniform scale + translation that keeps the tapped
    // point under the finger.
    _controller.value = Matrix4(
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, 1, 0, //
      -p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image.network(
            widget.photo.fullUrl,
            fit: BoxFit.contain,
            headers: widget.headers,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              // The small thumbnail is already cached: show it while the big
              // picture downloads.
              return Stack(
                alignment: Alignment.center,
                children: [
                  Image.network(
                    widget.photo.thumbUrl,
                    fit: BoxFit.contain,
                    headers: widget.headers,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                  const Spinner(color: Colors.white),
                ],
              );
            },
            errorBuilder: (context, error, stack) => Image.network(
              widget.photo.thumbUrl,
              fit: BoxFit.contain,
              headers: widget.headers,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
