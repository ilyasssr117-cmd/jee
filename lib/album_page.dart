import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'image_headers.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'photo_saver.dart';
import 'photo_store.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/dialogs.dart';
import 'widgets/state_views.dart';

/// Loads every photo of one album, chunk after chunk, until the last one.
///
/// Chunk 0 is the album page, then the site's "load more" request is repeated
/// with from=1, 2, 3, ... until a request returns no picture at all. The photos
/// list grows while the chunks arrive.
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

  int _next = 0; // 0 = the album page, N >= 1 = "load more" from=N.
  int _stale = 0; // Chunks in a row without any new picture.
  int _run = 0;
  bool _disposed = false;
  Completer<void> _done = Completer<void>();

  /// Some image servers refuse pictures requested without a Referer (and a
  /// browser-like client name).
  Map<String, String>? get imageHeaders => imageHeadersFor(album.url);

  /// Completes when every chunk is loaded, or when loading stopped on an
  /// error (check [error]).
  Future<void> get done => _done.future;

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Starts (or, after an error, resumes) loading. Safe to call repeatedly.
  Future<void> load() async {
    if (loading || finished || _disposed) return;
    final run = ++_run;
    loading = true;
    error = null;
    if (_done.isCompleted) _done = Completer<void>();
    notifyListeners();

    while (!_disposed && run == _run && _next <= _maxChunks) {
      final List<AlbumPhoto> chunk;
      try {
        chunk = await videoRepository.getAlbumPhotos(album, chunk: _next);
      } catch (e) {
        if (_disposed || run != _run) return;
        loading = false;
        error = e;
        _complete();
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
      _stale = added == 0 ? _stale + 1 : 0;
      // The end: a request with no picture at all, or (safety against a site
      // that repeats the last page forever) three requests in a row with
      // nothing new. A repeated first page (from=1 can equal the page itself)
      // is normal and does not stop the loading.
      if (chunk.isEmpty || _stale >= 3) {
        loading = false;
        finished = true;
        _complete();
        notifyListeners();
        return;
      }
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_disposed && run == _run) {
      loading = false;
      finished = true;
      _complete();
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
    _complete();
    super.dispose();
  }
}

/// Which photos are ticked while "Select" mode is on.
class PhotoSelection extends ChangeNotifier {
  bool _active = false;
  final Set<String> ids = <String>{};

  bool get active => _active;

  void start([String? firstId]) {
    _active = true;
    if (firstId != null) ids.add(firstId);
    notifyListeners();
  }

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> all) {
    ids
      ..clear()
      ..addAll(all);
    notifyListeners();
  }

  /// Leaves select mode.
  void clear() {
    _active = false;
    ids.clear();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Saving to the phone
// ---------------------------------------------------------------------------

/// Saves pictures of [loader]'s album in Library > Albums. Without [only] the
/// whole album is saved (waiting first until every photo is listed).
Future<void> savePhotosToAlbums(
  BuildContext context,
  AlbumLoader loader, {
  List<AlbumPhoto>? only,
  String? modelName,
}) async {
  final store = PhotoStore.instance;
  if (store.jobFor(loader.album.id) != null) {
    showToast(context, 'Already saving this album.', aboveBar: false);
    return;
  }

  if (only == null && !loader.finished) {
    showToast(context, 'Loading the whole album first\u2026', aboveBar: false);
    unawaited(loader.load());
    await loader.done;
    if (!context.mounted) return;
    if (loader.error != null) {
      showToast(context, 'Couldn\u2019t load all the photos.', aboveBar: false);
      return;
    }
  }

  final photos = List<AlbumPhoto>.of(only ?? loader.photos);
  final todo = photos.length - store.savedCount(loader.album.id, photos);
  if (todo == 0) {
    showToast(context, 'Already saved in Albums.', aboveBar: false);
    return;
  }
  showToast(
    context,
    'Saving $todo photo${todo == 1 ? '' : 's'}\u2026',
    aboveBar: false,
  );

  final saved = await store.savePhotos(
    loader.album,
    photos,
    modelName: modelName,
    headers: null,
  );
  if (!context.mounted) return;
  showToast(
    context,
    saved == todo
        ? 'Saved $saved photo${saved == 1 ? '' : 's'} to Albums.'
        : 'Saved $saved of $todo photos.',
    aboveBar: false,
  );
}

/// Saves picture files into the phone's Photos app. If that is not possible
/// (plugin missing), the iOS share sheet is opened instead.
Future<void> sendToPhotos(BuildContext context, List<String> paths) async {
  if (paths.isEmpty) return;
  if (paths.length > 1) {
    showToast(
      context,
      'Saving ${paths.length} photos to Photos\u2026',
      aboveBar: false,
    );
  }

  final result = await PhotoSaver.saveToGallery(paths);
  if (!context.mounted) return;

  if (result.denied) {
    showToast(
      context,
      'Allow access to Photos in Settings to save pictures.',
      aboveBar: false,
    );
    return;
  }
  if (result.saved > 0) {
    final partial = result.failed > 0 ? ' (${result.failed} failed)' : '';
    showToast(
      context,
      result.saved == 1
          ? 'Saved to Photos.'
          : 'Saved ${result.saved} photos to Photos.$partial',
      aboveBar: false,
    );
    return;
  }

  // Nothing could be saved directly: fall back to the share sheet.
  const limit = 150; // The share sheet gets slow with more files than this.
  final batch = paths.length > limit ? paths.sublist(0, limit) : paths;
  final ok = await NativeBridge.instance.shareFiles(batch);
  if (!context.mounted) return;
  if (!ok) {
    showToast(context, 'Couldn\u2019t save to Photos.', aboveBar: false);
  } else if (paths.length > limit) {
    showToast(
      context,
      'Sent the first $limit photos. Use Select for the rest.',
      aboveBar: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Album page
// ---------------------------------------------------------------------------

/// A whole album: back button, title, number of photos and the photo grid.
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, required this.album, this.modelName});

  final AlbumRef album;
  final String? modelName;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  late final AlbumLoader _loader = AlbumLoader(widget.album);
  final PhotoSelection _selection = PhotoSelection();

  @override
  void initState() {
    super.initState();
    _loader.load();
  }

  @override
  void dispose() {
    _selection.dispose();
    _loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      // Back leaves select mode first.
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
                          const SizedBox(height: Gaps.lg),
                          AlbumToolbar(
                            loader: _loader,
                            selection: _selection,
                            modelName: widget.modelName,
                          ),
                        ],
                      ),
                    ),
                  ),
                  PhotoGridSliver(
                    loader: _loader,
                    selection: _selection,
                    modelName: widget.modelName,
                    padding: EdgeInsets.symmetric(horizontal: margin),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: Gaps.xl + context.safe.bottom + 72,
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PhotoSelectionBar(
                  loader: _loader,
                  selection: _selection,
                  modelName: widget.modelName,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Select" and "Download all" under an album's title.
class AlbumToolbar extends StatelessWidget {
  const AlbumToolbar({
    super.key,
    required this.loader,
    required this.selection,
    this.modelName,
  });

  final AlbumLoader loader;
  final PhotoSelection selection;
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    final store = PhotoStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[loader, selection, store]),
      builder: (context, _) {
        final job = store.jobFor(loader.album.id);
        final photos = loader.photos;
        final allSaved = loader.finished &&
            photos.isNotEmpty &&
            store.savedCount(loader.album.id, photos) == photos.length;

        final String downloadLabel;
        final IconData downloadIcon;
        final VoidCallback downloadAction;
        if (job != null) {
          downloadLabel = 'Saving ${job.done}/${job.total} \u00b7 Stop';
          downloadIcon = Icons.close_rounded;
          downloadAction = () => store.cancel(loader.album.id);
        } else if (allSaved) {
          downloadLabel = 'Saved in Albums';
          downloadIcon = Icons.download_done_rounded;
          downloadAction = () => showToast(
                context,
                'Find it in Library > Albums.',
                aboveBar: false,
              );
        } else {
          downloadLabel = 'Download all';
          downloadIcon = Icons.download_rounded;
          downloadAction = () => savePhotosToAlbums(
                context,
                loader,
                modelName: modelName,
              );
        }

        return Wrap(
          spacing: Gaps.sm,
          runSpacing: Gaps.sm,
          children: [
            AppButton(
              label: selection.active ? 'Cancel' : 'Select',
              icon: selection.active
                  ? Icons.close_rounded
                  : Icons.check_circle_outline_rounded,
              style: AppButtonStyle.secondary,
              onPressed: () =>
                  selection.active ? selection.clear() : selection.start(),
            ),
            AppButton(
              label: downloadLabel,
              icon: downloadIcon,
              onPressed: downloadAction,
            ),
          ],
        );
      },
    );
  }
}

/// Bar at the bottom while photos are being selected: count, All, Download.
class PhotoSelectionBar extends StatelessWidget {
  const PhotoSelectionBar({
    super.key,
    required this.loader,
    required this.selection,
    this.modelName,
  });

  final AlbumLoader loader;
  final PhotoSelection selection;
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[loader, selection]),
      builder: (context, _) {
        if (!selection.active) return const SizedBox.shrink();
        final count = selection.ids.length;
        return Container(
          padding: EdgeInsets.fromLTRB(
            context.hMargin,
            Gaps.md,
            context.hMargin,
            Gaps.md + context.safe.bottom,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            border: Border(top: BorderSide(color: AppColors.outline)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  count == 0 ? 'Select photos' : '$count selected',
                  style: AppText.label,
                ),
              ),
              AppButton(
                label: 'All',
                style: AppButtonStyle.secondary,
                onPressed: () =>
                    selection.selectAll(loader.photos.map((p) => p.id)),
              ),
              const SizedBox(width: Gaps.sm),
              AppButton(
                label: 'Download',
                icon: Icons.download_rounded,
                onPressed: () async {
                  if (count == 0) {
                    showToast(context, 'Tap photos to select them.',
                        aboveBar: false);
                    return;
                  }
                  final chosen = [
                    for (final p in loader.photos)
                      if (selection.ids.contains(p.id)) p,
                  ];
                  selection.clear();
                  await savePhotosToAlbums(
                    context,
                    loader,
                    only: chosen,
                    modelName: modelName,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Photo grid
// ---------------------------------------------------------------------------

/// Photo grid (3 per row) for an [AlbumLoader]. Tapping opens the full-screen
/// viewer; with a [selection], long-press starts select mode and taps tick
/// photos. Shows a skeleton while the first chunk loads and a Retry row when
/// a chunk fails.
class PhotoGridSliver extends StatelessWidget {
  const PhotoGridSliver({
    super.key,
    required this.loader,
    this.selection,
    this.modelName,
    this.padding = EdgeInsets.zero,
  });

  final AlbumLoader loader;
  final PhotoSelection? selection;
  final String? modelName;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final store = PhotoStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        loader,
        store,
        if (selection != null) selection!,
      ]),
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

        final selecting = selection?.active ?? false;
        return SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final photo = photos[index];
                    return _PhotoTile(
                      key: ValueKey<String>(photo.id),
                      image: NetworkImage(
                        photo.thumbUrl,
                        headers: loader.imageHeaders,
                      ),
                      selecting: selecting,
                      selected: selection?.ids.contains(photo.id) ?? false,
                      saved: store.isSaved(loader.album.id, photo.id),
                      onTap: () {
                        if (selecting) {
                          selection!.toggle(photo.id);
                        } else {
                          _openViewer(context, index);
                        }
                      },
                      onLongPress: selection == null || selecting
                          ? null
                          : () => selection!.start(photo.id),
                    );
                  },
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

  void _openViewer(BuildContext context, int index) {
    final headers = loader.imageHeaders;
    openPhotoViewer(
      context,
      PhotoViewerPage(
        listenable: loader,
        items: () => <ViewerItem>[
          for (final p in loader.photos)
            ViewerItem(
              id: p.id,
              thumb: NetworkImage(p.thumbUrl, headers: headers),
              full: NetworkImage(p.fullUrl, headers: headers),
              remote: p,
            ),
        ],
        isLoading: () => loader.loading,
        album: loader.album,
        modelName: modelName,
        initialIndex: index,
      ),
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

/// An album: its (portrait) preview picture and title.
class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.subtitle,
  });

  final AlbumRef album;
  final VoidCallback onTap;
  final String? subtitle;

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
                        headers: imageHeadersFor(album.url),
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
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
        ],
      ),
    );
  }
}

/// One grid tile: the picture, a tick while selecting and a small badge when
/// it is already saved on the phone.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.image,
    required this.selecting,
    required this.selected,
    required this.saved,
    required this.onTap,
    required this.onLongPress,
  });

  final ImageProvider image;
  final bool selecting;
  final bool selected;
  final bool saved;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Pressable(
      semanticLabel: selected ? 'Photo, selected' : 'Photo',
      haptic: selecting ? Haptic.selection : Haptic.none,
      pressedScale: 0.97,
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: AppColors.surfaceHigh,
              child: Image(
                image: ResizeImage(
                  image,
                  width: (160 * dpr).round(),
                  allowUpscaling: false,
                ),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            if (selected)
              const ColoredBox(color: Color(0x554C93FF)),
            if (selecting)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? AppColors.blue : const Color(0x66000000),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: selected
                      ? const Icon(Icons.check_rounded,
                          size: 15, color: Colors.white)
                      : null,
                ),
              )
            else if (saved)
              const Positioned(
                right: 6,
                bottom: 6,
                child: _SavedBadge(),
              ),
          ],
        ),
      ),
    );
  }
}

class _SavedBadge extends StatelessWidget {
  const _SavedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xCC1FA971),
      ),
      child: const Icon(Icons.download_done_rounded,
          size: 14, color: Colors.white),
    );
  }
}

// ---------------------------------------------------------------------------
// Full-screen viewer
// ---------------------------------------------------------------------------

/// One picture in the viewer. [remote] is set for pictures that can still be
/// downloaded; [localPath] for pictures already saved on the phone.
class ViewerItem {
  const ViewerItem({
    required this.id,
    required this.thumb,
    required this.full,
    this.remote,
    this.localPath,
  });

  final String id;
  final ImageProvider thumb;
  final ImageProvider full;
  final AlbumPhoto? remote;
  final String? localPath;
}

void openPhotoViewer(BuildContext context, PhotoViewerPage page) {
  Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Full-screen photo viewer: swipe between photos, pinch or double-tap to
/// zoom. Top right: download (save in Albums) and share (Save to Photos).
/// Photos still loading are added to the end while the viewer is open.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.listenable,
    required this.items,
    required this.initialIndex,
    this.isLoading,
    this.album,
    this.modelName,
  });

  /// Notifies when [items] changed.
  final Listenable listenable;
  final List<ViewerItem> Function() items;
  final int initialIndex;
  final bool Function()? isLoading;

  /// Needed to save remote pictures.
  final AlbumRef? album;
  final String? modelName;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;
  bool _busy = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Local file of [item]: saved before, or saved right now.
  Future<String?> _ensureLocalPath(ViewerItem item) async {
    final local = item.localPath;
    if (local != null) return local;
    final remote = item.remote;
    final album = widget.album;
    if (remote == null || album == null) return null;

    final store = PhotoStore.instance;
    if (!store.isSaved(album.id, remote.id)) {
      await store.savePhotos(
        album,
        <AlbumPhoto>[remote],
        modelName: widget.modelName,
      );
    }
    final saved = store.album(album.id);
    final photo = saved?.photos.where((p) => p.id == remote.id).firstOrNull;
    if (saved == null || photo == null) return null;
    return store.fileOf(saved, photo).path;
  }

  Future<void> _download(ViewerItem item) async {
    final remote = item.remote;
    final album = widget.album;
    if (remote == null || album == null || _busy) return;
    final store = PhotoStore.instance;
    if (store.isSaved(album.id, remote.id)) {
      showToast(context, 'Already saved in Albums.', aboveBar: false);
      return;
    }
    setState(() => _busy = true);
    final saved = await store.savePhotos(
      album,
      <AlbumPhoto>[remote],
      modelName: widget.modelName,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
      context,
      saved == 1 ? 'Saved to Albums.' : 'Couldn\u2019t save this photo.',
      aboveBar: false,
    );
  }

  Future<void> _share(ViewerItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    final path = await _ensureLocalPath(item);
    if (!mounted) return;
    setState(() => _busy = false);
    if (path == null) {
      showToast(context, 'Couldn\u2019t prepare this photo.', aboveBar: false);
      return;
    }
    await sendToPhotos(context, <String>[path]);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: Listenable.merge(
            <Listenable>[widget.listenable, PhotoStore.instance],
          ),
          builder: (context, _) {
            final items = widget.items();
            final current = items.isEmpty
                ? null
                : items[_index.clamp(0, items.length - 1)];
            final album = widget.album;
            final isSaved = current?.localPath != null ||
                (current?.remote != null &&
                    album != null &&
                    PhotoStore.instance.isSaved(album.id, current!.remote!.id));
            final canDownload =
                current?.remote != null && album != null && !isSaved;

            return Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pages,
                  // While zoomed in, dragging pans the picture instead.
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: items.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) => _ZoomablePhoto(
                    key: ValueKey<String>(items[index].id),
                    item: items[index],
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
                      if (items.isNotEmpty)
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
                            '${_index + 1} / ${items.length}'
                            '${(widget.isLoading?.call() ?? false) ? '+' : ''}',
                            style: AppText.label.copyWith(color: Colors.white),
                          ),
                        ),
                      const Spacer(),
                      if (current != null) ...[
                        if (canDownload || (isSaved && current.remote != null))
                          RoundIconButton(
                            icon: isSaved
                                ? Icons.download_done_rounded
                                : Icons.download_rounded,
                            iconSize: 20,
                            label: isSaved ? 'Saved in Albums' : 'Download',
                            onTap: () => _download(current),
                          ),
                        const SizedBox(width: Gaps.sm),
                        RoundIconButton(
                          icon: Icons.ios_share_rounded,
                          iconSize: 20,
                          label: 'Save to Photos',
                          onTap: () => _share(current),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_busy)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: Spinner(color: Colors.white)),
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
    required this.item,
    required this.onZoomChanged,
  });

  final ViewerItem item;
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
    final item = widget.item;
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image(
            image: item.full,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              // The small thumbnail is already cached: show it while the big
              // picture downloads.
              return Stack(
                alignment: Alignment.center,
                children: [
                  Image(
                    image: item.thumb,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                  const Spinner(color: Colors.white),
                ],
              );
            },
            errorBuilder: (context, error, stack) => Image(
              image: item.thumb,
              fit: BoxFit.contain,
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
