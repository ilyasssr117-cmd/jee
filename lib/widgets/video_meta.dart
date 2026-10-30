import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';

class VideoMetaLine extends StatelessWidget {
  const VideoMetaLine({
    super.key,
    required this.video,
    this.style,
    this.showDuration = false,
    this.showDate = false,
    this.showCategory = false,
    this.fallbackToCategory = true,
  });

  final Video video;
  final TextStyle? style;
  final bool showDuration;
  final bool showDate;
  final bool showCategory;
  final bool fallbackToCategory;

  bool get hasContent =>
      (showDuration && video.duration.isNotEmpty) ||
      (showDate && video.date.isNotEmpty) ||
      video.likes.isNotEmpty ||
      video.views.isNotEmpty ||
      ((showCategory || fallbackToCategory) && video.category.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final style = this.style ?? AppText.caption;
    final parts = <Widget>[];

    void separator() {
      if (parts.isEmpty) return;
      parts.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('\u2022', style: style),
        ),
      );
    }

    if (showDuration && video.duration.isNotEmpty) {
      parts.add(Text(video.duration, maxLines: 1, style: style));
    }

    if (video.likes.isNotEmpty) {
      separator();
      parts.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.thumb_up_alt_rounded,
              size: (style.fontSize ?? 12) + 1,
              color: AppColors.accent,
            ),
            const SizedBox(width: 4),
            Text(video.likes, maxLines: 1, style: style),
          ],
        ),
      );
    }

    if (video.views.isNotEmpty) {
      separator();
      parts.add(
        Flexible(child: _IconText(Icons.visibility_outlined, video.views, style)),
      );
    }

    if (showDate && video.date.isNotEmpty) {
      separator();
      parts.add(
        Flexible(
          child: _IconText(Icons.calendar_today_outlined, video.date, style),
        ),
      );
    }

    final showCat = video.category.isNotEmpty &&
        (showCategory || (fallbackToCategory && parts.isEmpty));
    if (showCat) {
      separator();
      parts.add(
        Flexible(
          child: Text(
            video.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      );
    }

    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: parts);
  }
}

class _IconText extends StatelessWidget {
  const _IconText(this.icon, this.text, this.style);

  final IconData icon;
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: (style.fontSize ?? 12) + 2,
          color: style.color ?? AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}
