import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorites_store.dart';
import '../models.dart';
import 'state_views.dart';
import 'video_grid.dart';

/// The Favorites section of the home screen (shown next to the sidebar).
class FavoritesView extends StatefulWidget {
  const FavoritesView({
    super.key,
    required this.onOpen,
    required this.onBrowse,
    this.rightInset = 0,
    this.bottomInset = 0,
  });

  /// Space kept free at the bottom (the floating bar on phones).
  final double bottomInset;

  /// Space kept free at the right edge (the floating sidebar).
  final double rightInset;

  /// Opens [video]; [queue] is the favourites list (used by Autoplay Next).
  final void Function(Video video, List<Video> queue) onOpen;
  final VoidCallback onBrowse;

  @override
  State<FavoritesView> createState() => _FavoritesViewState();
}

class _FavoritesViewState extends State<FavoritesView> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _firstNode = FocusNode(debugLabel: 'First favorite');
  int _lastCount = -1;

  @override
  void dispose() {
    _firstNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final inset = widget.rightInset;
    // One listener for the whole section.
    return ListenableBuilder(
      listenable: FavoritesStore.instance,
      builder: (context, _) {
        final items = FavoritesStore.instance.items;
        // A card was just removed (hold OK): its focus is gone, so hand it to
        // the first card. Only when this screen is on top, never while a
        // details page covers it.
        if (_lastCount > items.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
            if (_firstNode.context != null) _firstNode.requestFocus();
          });
        }
        _lastCount = items.length;
        return CustomScrollView(
          controller: _scroll,
          cacheExtent: MediaQuery.sizeOf(context).height,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  context.s(Gaps.screenV + Gaps.md) + context.safe.top,
                  margin + inset,
                  context.s(Gaps.md),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.star_rounded,
                      size: context.s(34),
                      color: AppColors.star,
                    ),
                    SizedBox(width: context.s(Gaps.md - 4)),
                    Text('Favorites', style: AppText.headline),
                    if (items.isNotEmpty) ...[
                      SizedBox(width: context.s(Gaps.md)),
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
                  padding: EdgeInsets.only(right: inset),
                  child: TvStatusView(
                  icon: Icons.star_border_rounded,
                  title: 'No favorites yet',
                  message: 'Open a video and choose \u201cAdd to Favorites\u201d.',
                  actionLabel: 'Browse videos',
                  actionIcon: Icons.home_rounded,
                  onAction: widget.onBrowse,
                  ),
                ),
              )
            else
              SliverVideoGrid(
                videos: items,
                firstItemFocusNode: _firstNode,
                padding: EdgeInsets.fromLTRB(
                  margin,
                  context.s(Gaps.sm),
                  margin + inset,
                  context.s(Gaps.xxl) + widget.bottomInset,
                ),
                onOpen: (video) =>
                    widget.onOpen(video, List<Video>.of(items)),
              ),
          ],
        );
      },
    );
  }
}
