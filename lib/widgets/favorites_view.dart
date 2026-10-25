import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorites_store.dart';
import '../models.dart';
import 'state_views.dart';
import 'video_grid.dart';

/// The Favorites tab of the home screen.
class FavoritesView extends StatelessWidget {
  const FavoritesView({
    super.key,
    required this.onOpen,
    required this.onBrowse,
    this.bottomInset = 0,
  });

  /// Space kept free at the bottom (the floating bar).
  final double bottomInset;

  /// Opens [video]; [queue] is the favourites list (used by Autoplay Next).
  final void Function(Video video, List<Video> queue) onOpen;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: FavoritesStore.instance,
      builder: (context, _) {
        final items = FavoritesStore.instance.items;
        return CustomScrollView(
          cacheExtent: MediaQuery.sizeOf(context).height,
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
                    Icon(
                      Icons.star_rounded,
                      size: 24,
                      color: AppColors.star,
                    ),
                    const SizedBox(width: Gaps.sm),
                    Text('Saved videos', style: AppText.headline),
                    if (items.isNotEmpty) ...[
                      const SizedBox(width: Gaps.sm),
                      Text('${items.length}', style: AppText.body),
                    ],
                  ],
                ),
              ),
            ),
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottomInset),
                  child: StatusView(
                    icon: Icons.star_border_rounded,
                    title: 'No favorites yet',
                    message: 'Tap the star on any video to save it here.',
                    actionLabel: 'Browse videos',
                    actionIcon: Icons.home_rounded,
                    onAction: onBrowse,
                  ),
                ),
              )
            else
              SliverVideoGrid(
                videos: items,
                padding: EdgeInsets.fromLTRB(
                  margin,
                  Gaps.xs,
                  margin,
                  Gaps.xl + bottomInset,
                ),
                onOpen: (video) => onOpen(video, List<Video>.of(items)),
              ),
          ],
        );
      },
    );
  }
}
