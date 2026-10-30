import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../album_page.dart';
import '../app_theme.dart';
import '../photo_store.dart';
import '../touch.dart';
import 'app_button.dart';
import 'dialogs.dart';
import 'state_views.dart';

class SavedAlbumsView extends StatelessWidget {
  const SavedAlbumsView({
    super.key,
    required this.onBrowse,
    required this.bottomInset,
  });

  final VoidCallback onBrowse;

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: PhotoStore.instance,
      builder: (context, _) {
        final store = PhotoStore.instance;
        final albums = store.albums;
        if (albums.isEmpty) {
          return StatusView(
            icon: Icons.photo_library_outlined,
            title: 'No saved albums yet',
            message: 'Open a model, choose Photos, then tap Download to keep '
                'an album here.',
            actionLabel: 'Browse videos',
            actionIcon: Icons.home_rounded,
            onAction: onBrowse,
          );
        }
        final groups = <String, List<SavedAlbum>>{};
        for (final album in albums) {
          final name = (album.modelName ?? '').trim();
          groups.putIfAbsent(name.isEmpty ? 'Other albums' : name, () => <SavedAlbum>[]).add(album);
        }

        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(margin, Gaps.sm, margin, Gaps.xs),
              sliver: SliverToBoxAdapter(
                child: Text(
                  '${albums.length} album${albums.length == 1 ? '' : 's'}'
                  ' \u00b7 ${store.totalPhotos} photos',
                  style: AppText.caption,
                ),
              ),
            ),
            for (final entry in groups.entries) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(margin, Gaps.lg, margin, Gaps.sm),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      const Icon(Icons.person_rounded, size: 18, color: AppColors.accent),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.title,
                        ),
                      ),
                      Text(
                        '${entry.value.length} album${entry.value.length == 1 ? '' : 's'}',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: margin),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: Gaps.md,
                    mainAxisSpacing: Gaps.lg,
                    childAspectRatio: 0.62,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _SavedAlbumCard(
                      key: ValueKey<String>(entry.value[index].id),
                      album: entry.value[index],
                    ),
                    childCount: entry.value.length,
                  ),
                ),
              ),
            ],
            SliverToBoxAdapter(child: SizedBox(height: Gaps.xl + bottomInset)),
          ],
        );
      },
    );
  }
}

class _SavedAlbumCard extends StatelessWidget {
  const _SavedAlbumCard({super.key, required this.album});

  final SavedAlbum album;

  @override
  Widget build(BuildContext context) {
    final store = PhotoStore.instance;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final job = store.jobFor(album.id);
    final cover = album.photos.isEmpty
        ? null
        : store.fileOf(album, album.photos.first);
    final subtitle = [
      '${album.photos.length} photo${album.photos.length == 1 ? '' : 's'}',
      if (album.modelName != null && album.modelName!.isNotEmpty)
        album.modelName!,
    ].join(' \u00b7 ');

    return Pressable(
      semanticLabel: 'Album ${album.title}',
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SavedAlbumPage(albumId: album.id),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: AppColors.surfaceHigh,
                    child: cover == null
                        ? Icon(Icons.photo_library_outlined,
                            color: AppColors.textTertiary)
                        : Image.file(
                            cover,
                            fit: BoxFit.cover,
                            cacheWidth: (200 * dpr).round(),
                            errorBuilder: (context, error, stack) => Icon(
                              Icons.broken_image_outlined,
                              color: AppColors.textTertiary,
                            ),
                          ),
                  ),
                  if (job != null)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                        child: Text(
                          'Saving ${job.done}/${job.total}',
                          style: AppText.caption.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                ],
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
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption,
          ),
        ],
      ),
    );
  }
}

class SavedAlbumPage extends StatefulWidget {
  const SavedAlbumPage({super.key, required this.albumId});

  final String albumId;

  @override
  State<SavedAlbumPage> createState() => _SavedAlbumPageState();
}

class _SavedAlbumPageState extends State<SavedAlbumPage> {
  final PhotoSelection _selection = PhotoSelection();

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  List<String> _paths(SavedAlbum album, {Set<String>? only}) {
    final store = PhotoStore.instance;
    return [
      for (final photo in album.photos)
        if (only == null || only.contains(photo.id))
          store.fileOf(album, photo).path,
    ];
  }

  Future<void> _deleteAlbum(SavedAlbum album) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete this album?',
      message: '${album.photos.length} photos will be removed from this phone.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    await PhotoStore.instance.removeAlbum(album.id);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _deleteSelected(SavedAlbum album) async {
    final ids = Set<String>.of(_selection.ids);
    if (ids.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete ${ids.length} photo${ids.length == 1 ? '' : 's'}?',
      message: 'They will be removed from this phone.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    _selection.clear();
    for (final id in ids) {
      await PhotoStore.instance.removePhoto(album.id, id);
    }
  }

  void _open(SavedAlbum album, int index) {
    final store = PhotoStore.instance;
    openPhotoViewer(
      context,
      PhotoViewerPage(
        listenable: store,
        items: () {
          final current = store.album(album.id);
          if (current == null) return const <ViewerItem>[];
          return <ViewerItem>[
            for (final photo in current.photos)
              ViewerItem(
                id: photo.id,
                thumb: FileImage(store.fileOf(current, photo)),
                full: FileImage(store.fileOf(current, photo)),
                localPath: store.fileOf(current, photo).path,
              ),
          ];
        },
        initialIndex: index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    final store = PhotoStore.instance;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[store, _selection]),
        builder: (context, _) {
          final album = store.album(widget.albumId);
          return PopScope(
            canPop: !_selection.active,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _selection.clear();
            },
            child: Scaffold(
              backgroundColor: AppColors.background,
              body: album == null
                  ? const Center(
                      child: StatusView(
                        icon: Icons.photo_library_outlined,
                        title: 'Album removed',
                        message: 'This album is no longer on the phone.',
                      ),
                    )
                  : Stack(
                      children: [
                        CustomScrollView(
                          slivers: [
                            SliverToBoxAdapter(
                              child: _header(album, margin),
                            ),
                            SliverPadding(
                              padding: EdgeInsets.symmetric(horizontal: margin),
                              sliver: SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                  childAspectRatio: 3 / 4,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final photo = album.photos[index];
                                    return _LocalTile(
                                      key: ValueKey<String>(photo.id),
                                      file: store.fileOf(album, photo),
                                      selecting: _selection.active,
                                      selected:
                                          _selection.ids.contains(photo.id),
                                      onTap: () => _selection.active
                                          ? _selection.toggle(photo.id)
                                          : _open(album, index),
                                      onLongPress: _selection.active
                                          ? null
                                          : () => _selection.start(photo.id),
                                    );
                                  },
                                  childCount: album.photos.length,
                                ),
                              ),
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
                          child: _selectionBar(album),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(SavedAlbum album, double margin) {
    final n = album.photos.length;
    final subtitle = [
      '$n photo${n == 1 ? '' : 's'}',
      if (album.modelName != null && album.modelName!.isNotEmpty)
        album.modelName!,
    ].join(' \u00b7 ');
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
          Text(
            album.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.headline,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: Gaps.lg),
          Wrap(
            spacing: Gaps.sm,
            runSpacing: Gaps.sm,
            children: [
              AppButton(
                label: _selection.active ? 'Cancel' : 'Select',
                icon: _selection.active
                    ? Icons.close_rounded
                    : Icons.check_circle_outline_rounded,
                style: AppButtonStyle.secondary,
                onPressed: () =>
                    _selection.active ? _selection.clear() : _selection.start(),
              ),
              AppButton(
                label: 'Save all to Photos',
                icon: Icons.photo_library_outlined,
                onPressed: () => sendToPhotos(context, _paths(album)),
              ),
              AppButton(
                label: 'Delete',
                icon: Icons.delete_outline_rounded,
                style: AppButtonStyle.secondary,
                onPressed: () => _deleteAlbum(album),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _selectionBar(SavedAlbum album) {
    if (!_selection.active) return const SizedBox.shrink();
    final count = _selection.ids.length;
    return SelectionBarFrame(
      count: count,
      onSelectAll: () => _selection.selectAll(album.photos.map((p) => p.id)),
      actions: [
        Expanded(
          child: AppButton(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            style: AppButtonStyle.secondary,
            expand: true,
            onPressed: () => _deleteSelected(album),
          ),
        ),
        Expanded(
          flex: 2,
          child: AppButton(
            label: 'Save to Photos',
            icon: Icons.photo_library_outlined,
            expand: true,
            onPressed: () {
              if (count == 0) {
                showToast(context, 'Tap photos to select them.',
                    aboveBar: false);
                return;
              }
              sendToPhotos(context, _paths(album, only: _selection.ids));
            },
          ),
        ),
      ],
    );
  }
}

class _LocalTile extends StatelessWidget {
  const _LocalTile({
    super.key,
    required this.file,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final File file;
  final bool selecting;
  final bool selected;
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
              child: Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: (160 * dpr).round(),
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            if (selected) const ColoredBox(color: Color(0x554C93FF)),
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
              ),
          ],
        ),
      ),
    );
  }
}
