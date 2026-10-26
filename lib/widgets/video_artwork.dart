import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';

/// Thumbnail with consistent clipping, a fade-in, and a designed placeholder
/// for loading / missing / failed images. Fills its parent, so the parent
/// decides the aspect ratio and the image can never cause a layout shift.
class VideoArtwork extends StatelessWidget {
  const VideoArtwork({
    super.key,
    required this.video,
    this.borderRadius = 0,
    this.showLabel = true,
  });

  final Video video;

  /// Corner radius in logical pixels (0 = no clipping).
  final double borderRadius;

  /// Show the title inside the placeholder when there is no usable image.
  final bool showLabel;

  static Map<String, String>? _headersFor(Video video) {
    final page = Uri.tryParse(video.pageUrl ?? '');
    if (page == null ||
        (page.scheme != 'http' && page.scheme != 'https') ||
        page.host.isEmpty) {
      return null;
    }
    // Some CDNs reject hot-linked thumbnails without a Referer.
    return <String, String>{'Referer': '${page.origin}/'};
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final url = video.thumbnailUrl?.trim() ?? '';
        final uri = Uri.tryParse(url);
        final valid = uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;

        if (!valid) return _Placeholder(video: video, showLabel: showLabel);

        // Decode no larger than needed, quantised so the image cache is reused.
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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceHigh, AppColors.background],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_circle_outline_rounded,
                size: 36,
                color: AppColors.textTertiary,
              ),
              if (showLabel) ...[
                const SizedBox(height: 6),
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
