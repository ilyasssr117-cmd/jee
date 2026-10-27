import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../download_store.dart';
import '../favorites_store.dart';
import '../history_store.dart';
import '../models.dart';
import '../playback_launcher.dart';
import '../playback_progress.dart';
import '../preview_manager.dart';
import '../touch.dart';
import 'app_button.dart';
import 'dialogs.dart';
import 'favorite_models_view.dart';
import 'saved_albums_view.dart';
import 'state_views.dart';
import 'video_artwork.dart';
import 'video_grid.dart';
import 'video_preview.dart';

enum LibrarySegment { favorites, models, history, downloads, albums }

/// The Library tab: Favorites, History, Downloads and saved photo Albums.
class LibraryView extends StatefulWidget {
  const LibraryView({
    super.key,
    required this.onOpen,
    required this.onBrowse,
    required this.bottomInset,
  });

  /// Opens [video]'s page; [queue] is the list it came from.
  final void Function(Video video, List<Video> queue) onOpen;
  final VoidCallback onBrowse;

  /// Space kept free at the bottom (the floating bar).
  final double bottomInset;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  LibrarySegment _segment = LibrarySegment.favorites;

  static const Map<LibrarySegment, String> _labels = <LibrarySegment, String>{
    LibrarySegment.favorites: 'Favorites',
    LibrarySegment.models: 'Models',
    LibrarySegment.history: 'History',
    LibrarySegment.downloads: 'Downloads',
    LibrarySegment.albums: 'Albums',
  };

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            margin,
            context.safe.top + Gaps.lg,
            margin,
            Gaps.sm,
          ),
          child: Row(
            children: [
              Expanded(child: Text('Library', style: AppText.headline)),
              if (_segment == LibrarySegment.history)
                ListenableBuilder(
                  listenable: HistoryStore.instance,
                  builder: (context, _) => HistoryStore.instance.items.isEmpty
                      ? const SizedBox.shrink()
                      : _TextAction(label: 'Clear', onTap: _confirmClearHistory),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: margin, vertical: 6),
            children: [
              for (final segment in LibrarySegment.values) ...[
                AppChip(
                  label: _labels[segment]!,
                  selected: segment == _segment,
                  onPressed: () => setState(() => _segment = segment),
                ),
                const SizedBox(width: Gaps.sm),
              ],
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.normal,
            child: KeyedSubtree(
              key: ValueKey<LibrarySegment>(_segment),
              child: switch (_segment) {
                LibrarySegment.favorites => _buildFavorites(margin),
                LibrarySegment.history => _buildHistory(margin),
                LibrarySegment.downloads => _buildDownloads(margin),
                LibrarySegment.models => FavoriteModelsView(
                    onBrowse: widget.onBrowse,
                    bottomInset: widget.bottomInset,
                  ),
                LibrarySegment.albums => SavedAlbumsView(
                    onBrowse: widget.onBrowse,
                    bottomInset: widget.bottomInset,
                  ),
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearHistory() async {
    final ok = await confirmDialog(
      context,
      title: 'Clear watch history?',
      message: 'Your list of watched videos will be removed.',
      confirmLabel: 'Clear',
    );
    if (ok) HistoryStore.instance.clear();
  }

  // -------------------------------------------------------------------------
  // Favorites
  // -------------------------------------------------------------------------

  Widget _buildFavorites(double margin) {
    return ListenableBuilder(
      listenable: FavoritesStore.instance,
      builder: (context, _) {
        final items = FavoritesStore.instance.items;
        if (items.isEmpty) {
          return StatusView(
            icon: Icons.star_border_rounded,
            title: 'No favorites yet',
            message: 'Tap the star on any video to save it here.',
            actionLabel: 'Browse videos',
            actionIcon: Icons.home_rounded,
            onAction: widget.onBrowse,
          );
        }
        return CustomScrollView(
          scrollCacheExtent: ScrollCacheExtent.pixels(
            MediaQuery.sizeOf(context).height,
          ),
          slivers: [
            SliverVideoGrid(
              videos: items,
              padding: EdgeInsets.fromLTRB(
                margin,
                Gaps.sm,
                margin,
                Gaps.xl + widget.bottomInset,
              ),
              onOpen: (video) => widget.onOpen(video, List<Video>.of(items)),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // History
  // -------------------------------------------------------------------------

  static String _group(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return 'This week';
    if (diff < 31) return 'This month';
    return 'Earlier';
  }

  static String _clock(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _when(DateTime time) {
    final group = _group(time);
    if (group == 'Today' || group == 'Yesterday') return _clock(time);
    return '${time.day} ${_months[time.month - 1]} \u00b7 ${_clock(time)}';
  }

  Widget _buildHistory(double margin) {
    return ListenableBuilder(
      listenable: HistoryStore.instance,
      builder: (context, _) {
        final entries = HistoryStore.instance.items;
        if (entries.isEmpty) {
          return StatusView(
            icon: Icons.history_rounded,
            title: 'Nothing watched yet',
            message: 'Videos you play will show up here.',
            actionLabel: 'Browse videos',
            actionIcon: Icons.home_rounded,
            onAction: widget.onBrowse,
          );
        }

        final queue = <Video>[for (final entry in entries) entry.video];
        final rows = <Widget>[];
        String? lastGroup;
        for (final entry in entries) {
          final group = _group(entry.playedAt);
          if (group != lastGroup) {
            lastGroup = group;
            rows.add(_SectionHeader(group));
          }
          final video = entry.video;
          final progress = PlaybackProgress.instance;
          final completed = progress.isCompleted(video.id);
          final fraction = completed ? null : progress.fraction(video.id);
          final status = completed
              ? 'Watched'
              : (fraction != null
                  ? '${(fraction * 100).round()}% watched'
                  : video.duration);
          rows.add(
            Dismissible(
              key: ValueKey<String>('history-${video.id}'),
              direction: DismissDirection.endToStart,
              background: const _DeleteBackground(),
              onDismissed: (_) {
                Haptics.play(Haptic.medium);
                HistoryStore.instance.remove(video.id);
              },
              child: _VideoRow(
                video: video,
                title: video.title,
                subtitle: status.isEmpty
                    ? _when(entry.playedAt)
                    : '${_when(entry.playedAt)} \u00b7 $status',
                watchedFraction: fraction,
                onTap: () => widget.onOpen(video, queue),
              ),
            ),
          );
        }

        return ListView(
          scrollCacheExtent: ScrollCacheExtent.pixels(
            MediaQuery.sizeOf(context).height,
          ),
          padding: EdgeInsets.fromLTRB(
            margin,
            0,
            margin,
            Gaps.xl + widget.bottomInset,
          ),
          children: rows,
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Downloads
  // -------------------------------------------------------------------------

  Future<void> _playSaved(DownloadItem item) async {
    final queue = <Video>[
      for (final entry in DownloadStore.instance.items)
        if (entry.status == DownloadStatus.done) entry.video,
    ];
    final error = await launchPlayer(context, item.video, queue: queue);
    if (!mounted) return;
    if (error != null) showToast(context, error);
  }

  Widget _buildDownloads(double margin) {
    return ListenableBuilder(
      listenable: DownloadStore.instance,
      builder: (context, _) {
        final store = DownloadStore.instance;
        final items = store.items;
        if (items.isEmpty) {
          return StatusView(
            icon: Icons.download_for_offline_outlined,
            title: 'No downloads yet',
            message: 'Open a video and tap Download to watch it offline.',
            actionLabel: 'Browse videos',
            actionIcon: Icons.home_rounded,
            onAction: widget.onBrowse,
          );
        }

        final rows = <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: Gaps.sm),
            child: Text(
              '${store.doneCount} saved \u00b7 ${formatBytes(store.totalBytes)}',
              style: AppText.caption,
            ),
          ),
        ];
        for (final item in items) {
          final video = item.video;
          rows.add(
            Dismissible(
              key: ValueKey<String>('download-${video.id}'),
              direction: DismissDirection.endToStart,
              background: const _DeleteBackground(),
              confirmDismiss: (_) => item.status == DownloadStatus.downloading
                  ? Future<bool>.value(true)
                  : confirmDialog(
                      context,
                      title: 'Delete this download?',
                      message: 'The video will be removed from your phone.',
                      confirmLabel: 'Delete',
                    ),
              onDismissed: (_) {
                Haptics.play(Haptic.medium);
                store.remove(video.id);
              },
              child: _DownloadRow(
                item: item,
                onTap: item.status == DownloadStatus.done
                    ? () => _playSaved(item)
                    : null,
              ),
            ),
          );
        }
        return ListView(
          scrollCacheExtent: ScrollCacheExtent.pixels(
            MediaQuery.sizeOf(context).height,
          ),
          padding: EdgeInsets.fromLTRB(
            margin,
            Gaps.xs,
            margin,
            Gaps.xl + widget.bottomInset,
          ),
          children: rows,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: label,
      haptic: Haptic.selection,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: AppColors.blue,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Gaps.md, bottom: Gaps.sm),
      child: Text(
        label,
        style: AppText.label.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 22),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Icon(Icons.delete_outline_rounded, color: AppColors.error),
    );
  }
}

/// Thumbnail on the left, text on the right.
class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.video,
    required this.title,
    required this.subtitle,
    this.subtitleColor,
    this.watchedFraction,
    this.below,
    this.trailing,
    this.onTap,
  });

  final Video video;
  final String title;
  final String subtitle;
  final Color? subtitleColor;
  final double? watchedFraction;

  /// Extra line under the subtitle (download progress bar).
  final Widget? below;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: title,
      pressedScale: 0.98,
      onTap: onTap == null
          ? null
          : () {
              PreviewManager.instance.stopNow(fade: false);
              onTap!();
            },
      // Hold the thumbnail to play a preview (with sound), like on the cards.
      onLongPress: () => PreviewManager.instance.requestPreview(video),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 128,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoArtwork(video: video),
                      PreviewSlot(video: video),
                      if (video.duration.isNotEmpty)
                        Positioned(
                          right: 5,
                          bottom: watchedFraction == null ? 5 : 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xCC000000),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              child: Text(
                                video.duration,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (watchedFraction != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SizedBox(
                            height: 3,
                            child: DecoratedBox(
                              decoration:
                                  const BoxDecoration(color: Color(0x80000000)),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: watchedFraction,
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: AppColors.accent,
                                    ),
                                    child: SizedBox.expand(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: Gaps.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.cardTitle.copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: subtitleColor),
                  ),
                  if (below != null) ...[const SizedBox(height: 6), below!],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Gaps.xs),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.item, this.onTap});

  final DownloadItem item;
  final VoidCallback? onTap;

  static Widget _bar(DownloadItem item, {required bool waiting}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        minHeight: 3,
        value: waiting ? 0 : item.progress,
        color: AppColors.accent,
        backgroundColor: AppColors.surfaceHigh,
      ),
    );
  }

  static String _amount(DownloadItem item, int done) => item.bytesTotal > 0
      ? '${formatBytes(done)} of ${formatBytes(item.bytesTotal)}'
      : formatBytes(done);

  @override
  Widget build(BuildContext context) {
    final store = DownloadStore.instance;
    final video = item.video;

    switch (item.status) {
      case DownloadStatus.done:
        return _VideoRow(
          video: video,
          title: video.title,
          subtitle: '${formatBytes(item.bytesTotal)} \u00b7 Saved offline',
          onTap: onTap,
          // "Add to device": the iOS share sheet (Save Video / Save to Files).
          trailing: _IconAction(
            icon: Icons.ios_share_rounded,
            label: 'Save to phone',
            onTap: () async {
              final ok = await store.shareFile(video.id);
              if (!ok && context.mounted) {
                showToast(context, 'Couldn\u2019t open the share sheet.');
              }
            },
          ),
        );

      case DownloadStatus.failed:
      case DownloadStatus.paused:
        final paused = item.status == DownloadStatus.paused;
        return ValueListenableBuilder<int>(
          valueListenable: item.bytes,
          builder: (context, done, _) => _VideoRow(
            video: video,
            title: video.title,
            subtitle: paused
                ? (item.hasPartial
                    ? 'Paused \u00b7 ${_amount(item, done)}'
                    : 'Paused')
                : (item.error ?? 'Download failed'),
            subtitleColor: paused ? null : AppColors.error,
            below: item.hasPartial ? _bar(item, waiting: false) : null,
            trailing: _IconAction(
              icon: item.hasPartial
                  ? Icons.play_circle_outline_rounded
                  : Icons.refresh_rounded,
              label: 'Resume download',
              onTap: () => store.resume(video.id),
            ),
          ),
        );

      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return ValueListenableBuilder<int>(
          valueListenable: item.bytes,
          builder: (context, done, _) {
            final waiting = item.status == DownloadStatus.queued;
            final fraction = item.progress;
            final text = waiting
                ? 'Waiting\u2026'
                : (fraction != null
                    ? '${(fraction * 100).round()}% \u00b7 ${_amount(item, done)}'
                    : 'Downloading \u00b7 ${formatBytes(done)}');
            return _VideoRow(
              video: video,
              title: video.title,
              subtitle: text,
              below: _bar(item, waiting: waiting),
              trailing: _IconAction(
                icon: Icons.pause_circle_outline_rounded,
                label: 'Pause download',
                onTap: () => store.pause(video.id),
              ),
            );
          },
        );
    }
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: label,
      pressedScale: 0.85,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 22, color: AppColors.textSecondary),
      ),
    );
  }
}
