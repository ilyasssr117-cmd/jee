import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../design_tokens.dart';
import '../models.dart';
import 'tv_controls.dart';
import 'video_artwork.dart';

/// Television Home (Phase 6): vertically stacked shelves navigated
/// with UP/DOWN between rows and LEFT/RIGHT inside a row — the
/// streaming-service model the TV design doc promised, instead of the
/// phone grid enlarged.
///
/// Data honesty: shelves are built ONLY from the videos the existing
/// repository already loaded for Home (featured + feed + grid). The
/// portrait shelf does not pretend landscape videos are portrait —
/// it is the entry point to Reels, which is the app's real vertical
/// (9:16) content.
class TvHomeShelves extends StatelessWidget {
  const TvHomeShelves({
    super.key,
    required this.featured,
    required this.videos,
    required this.onOpen,
    required this.onOpenReels,
    this.loading = false,
  });

  final Video? featured;
  final List<Video> videos;
  final ValueChanged<Video> onOpen;
  final VoidCallback onOpenReels;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final hero = featured;
    final rest = videos.where((v) => hero == null || v.id != hero.id).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 28, 48, 48),
      children: [
        if (hero != null) _hero(context, hero),
        if (hero != null) const SizedBox(height: VxSpace.xxl),
        _shelfTitle('Latest videos'),
        const SizedBox(height: VxSpace.md),
        _landscapeRow(rest.take(14).toList()),
        const SizedBox(height: VxSpace.xxl),
        _shelfTitle('Reels — vertical videos'),
        const SizedBox(height: VxSpace.md),
        _portraitEntry(context),
        if (rest.length > 14) ...[
          const SizedBox(height: VxSpace.xxl),
          _shelfTitle('More to explore'),
          const SizedBox(height: VxSpace.md),
          _landscapeRow(rest.skip(14).take(14).toList()),
        ],
        if (loading)
          const Padding(
            padding: EdgeInsets.only(top: VxSpace.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _shelfTitle(String text) => Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: VxType.sectionTitle + 4,
          fontWeight: FontWeight.w700,
        ),
      );

  Widget _hero(BuildContext context, Video video) {
    return TvFocusSurface(
      autofocus: true,
      onPressed: () => onOpen(video),
      padding: EdgeInsets.zero,
      borderRadius: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(
          aspectRatio: 21 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoArtwork(video: video, showLabel: false, fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                    stops: [0.45, 1],
                  ),
                ),
              ),
              Positioned(
                left: 28,
                right: 28,
                bottom: 22,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'FEATURED',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_circle_rounded,
                            color: Colors.white, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'OK to open',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: VxType.tvMetadata,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _landscapeRow(List<Video> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 300 * 9 / 16 + 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: VxSpace.lg),
        itemBuilder: (context, index) {
          final video = items[index];
          return TvVideoCard(
            video: video,
            width: 300,
            onPressed: () => onOpen(video),
          );
        },
      ),
    );
  }

  /// Portrait 9:16 entry card for the app's real vertical content.
  Widget _portraitEntry(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TvFocusSurface(
        onPressed: onOpenReels,
        padding: EdgeInsets.zero,
        borderRadius: 16,
        child: SizedBox(
          width: 168,
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: VxBrand.heroWash,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.smart_display_rounded,
                      color: AppColors.accent, size: 44),
                  const SizedBox(height: 12),
                  const Text(
                    'Open Reels',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: VxType.tvCardTitle,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Vertical 9:16',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: VxType.tvMetadata,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
