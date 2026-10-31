import 'dart:io';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../download_store.dart';
import '../models.dart';


/// Keeps the shared thumbnail clipped throughout its flight instead of
/// allowing the image to become a sharp-edged rectangle between routes.
/// The source and destination are briefly cross-faded so different decoded
/// thumbnail sizes do not appear to pop at the end of the transition.
Widget videoArtworkHeroFlight(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final destinationRadius = const BorderRadius.vertical(
    bottom: Radius.circular(24),
  );
  final startRadius = flightDirection == HeroFlightDirection.push
      ? BorderRadius.circular(Radii.card)
      : destinationRadius;
  final endRadius = flightDirection == HeroFlightDirection.push
      ? destinationRadius
      : BorderRadius.circular(Radii.card);

  return AnimatedBuilder(
    animation: animation,
    child: Stack(
      fit: StackFit.expand,
      children: [
        fromHero.child,
        IgnorePointer(
          child: FadeTransition(
            opacity: animation.drive(
              CurveTween(curve: Curves.easeInOutCubic),
            ),
            child: toHero.child,
          ),
        ),
      ],
    ),
    builder: (context, child) {
      final t = Curves.easeInOutCubic.transform(animation.value);
      final radius = BorderRadius.lerp(startRadius, endRadius, t)!;
      return Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      );
    },
  );
}

class VideoArtwork extends StatelessWidget {
  const VideoArtwork({
    super.key,
    required this.video,
    this.borderRadius = 0,
    this.showLabel = true,
  });

  final Video video;

  final double borderRadius;

  final bool showLabel;

  static Map<String, String>? _headersFor(Video video) {
    final page = Uri.tryParse(video.pageUrl ?? '');
    if (page == null ||
        (page.scheme != 'http' && page.scheme != 'https') ||
        page.host.isEmpty) {
      return null;
    }
    return <String, String>{'Referer': '${page.origin}/'};
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final saved = DownloadStore.instance.thumbPath(video.id);
        if (saved != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: AppColors.surfaceHigh),
              Image.file(
                File(saved),
                fit: BoxFit.cover,
                cacheWidth: constraints.maxWidth.isFinite
                    ? (constraints.maxWidth * dpr).round().clamp(128, 1280).toInt()
                    : null,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (context, error, stackTrace) =>
                    _Placeholder(video: video, showLabel: showLabel),
              ),
            ],
          );
        }

        final url = video.thumbnailUrl?.trim() ?? '';
        final uri = Uri.tryParse(url);
        final valid = uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;

        if (!valid) return _Placeholder(video: video, showLabel: showLabel);

        int? cacheWidth;
        if (constraints.maxWidth.isFinite) {
          final px = constraints.maxWidth * dpr;
          cacheWidth = (((px + 63) ~/ 64) * 64).clamp(128, 1280).toInt();
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: AppColors.surfaceHigh),
            Image.network(
              url,
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
              headers: _headersFor(video),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: Motion.fade,
                  curve: Curves.easeOut,
                  child: child,
                );
              },
              errorBuilder: (context, error, stackTrace) =>
                  _Placeholder(video: video, showLabel: showLabel),
            ),
          ],
        );
      },
    );

    if (borderRadius > 0) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      );
    }
    return content;
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.video, required this.showLabel});

  final Video video;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2028), Color(0xFF17181E)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_circle_outline_rounded,
                size: 36,
                color: Colors.white24,
              ),
              if (showLabel) ...[
                const SizedBox(height: 6),
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(color: Colors.white38),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
