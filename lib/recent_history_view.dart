import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'models.dart';
import 'playback_progress.dart';
import 'recent_videos_store.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

enum _HistoryFilter { all, inProgress, watched }

class RecentHistoryView extends StatefulWidget {
  const RecentHistoryView({
    super.key,
    required this.bottomInset,
    required this.onOpen,
    required this.onClear,
  });

  final double bottomInset;
  final void Function(Video video, List<Video> queue) onOpen;
  final VoidCallback onClear;

  @override
  State<RecentHistoryView> createState() => _RecentHistoryViewState();
}

class _RecentHistoryViewState extends State<RecentHistoryView> {
  _HistoryFilter _filter = _HistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: RecentVideosStore.instance,
      builder: (context, _) {
        final all = RecentVideosStore.instance.items;
        final videos = all.where((video) {
          switch (_filter) {
            case _HistoryFilter.all:
              return true;
            case _HistoryFilter.inProgress:
              return PlaybackProgress.instance.resumePosition(video.id) != null;
            case _HistoryFilter.watched:
              return PlaybackProgress.instance.isCompleted(video.id);
          }
        }).toList(growable: false);

        return CustomScrollView(
          key: const PageStorageKey<String>('recent-history-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  context.safe.top + Gaps.lg,
                  margin,
                  Gaps.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your library', style: AppText.headline),
                          const SizedBox(height: 3),
                          Text(
                            '${all.length} recently played',
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                    if (all.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear watch history',
                        onPressed: widget.onClear,
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(margin, 0, margin, Gaps.md),
                child: SegmentedButton<_HistoryFilter>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _HistoryFilter.all, label: Text('All')),
                    ButtonSegment(
                      value: _HistoryFilter.inProgress,
                      label: Text('Continue'),
                    ),
                    ButtonSegment(
                      value: _HistoryFilter.watched,
                      label: Text('Watched'),
                    ),
                  ],
                  selected: <_HistoryFilter>{_filter},
                  onSelectionChanged: (selection) =>
                      setState(() => _filter = selection.first),
                ),
              ),
            ),
            if (videos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: widget.bottomInset),
                  child: StatusView(
                    icon: _filter == _HistoryFilter.watched
                        ? Icons.check_circle_outline_rounded
                        : Icons.history_rounded,
                    title: all.isEmpty
                        ? 'Nothing played yet'
                        : _filter == _HistoryFilter.watched
                            ? 'No watched videos yet'
                            : 'Nothing to continue',
                    message: all.isEmpty
                        ? 'Videos you play will appear here, ready to pick up again.'
                        : 'Try another filter to see your recent videos.',
                  ),
                ),
              )
            else
              SliverVideoGrid(
                videos: videos,
                padding: EdgeInsets.fromLTRB(
                  margin,
                  Gaps.xs,
                  margin,
                  Gaps.xl + widget.bottomInset,
                ),
                onOpen: (video) => widget.onOpen(video, List<Video>.of(videos)),
              ),
          ],
        );
      },
    );
  }
}
