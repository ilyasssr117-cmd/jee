import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';

/// Converts raw catalog counts to a compact value that fits video cards.
/// Text such as "views" is omitted because the adjacent icon identifies it.
String compactMetric(String raw) {
  final value = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (value.isEmpty) return value;

  final abbreviated = RegExp(
    r'^([0-9]+(?:[.,][0-9]+)?)\s*([kmb])\b',
    caseSensitive: false,
  ).firstMatch(value);
  if (abbreviated != null) {
    final amount = double.tryParse(abbreviated.group(1)!.replaceAll(',', '.'));
    if (amount == null) return value;
    return '${_metricNumber(amount)}${abbreviated.group(2)!.toUpperCase()}';
  }

  final count = RegExp(r'^([0-9][0-9., ]*)').firstMatch(value);
  if (count == null) return value;
  var number = count.group(1)!.replaceAll(' ', '');
  if (number.contains(',') && number.contains('.')) {
    if (number.lastIndexOf(',') > number.lastIndexOf('.')) {
      number = number.replaceAll('.', '').replaceAll(',', '.');
    } else {
      number = number.replaceAll(',', '');
    }
  } else if (number.contains(',')) {
    number = RegExp(r',\d{1,2}$').hasMatch(number)
        ? number.replaceAll(',', '.')
        : number.replaceAll(',', '');
  } else if (RegExp(r'\.\d{3}$').hasMatch(number)) {
    number = number.replaceAll('.', '');
  }

  final amount = double.tryParse(number);
  if (amount == null) return value;
  if (amount >= 999500000) return '${_metricNumber(amount / 1000000000)}B';
  if (amount >= 999500) return '${_metricNumber(amount / 1000000)}M';
  if (amount >= 1000) return '${_metricNumber(amount / 1000)}K';
  return _metricNumber(amount);
}

String _metricNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  final rounded = value.toStringAsFixed(1);
  return rounded.endsWith('.0')
      ? rounded.substring(0, rounded.length - 2)
      : rounded;
}

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
          child: Text(
            '\u2022',
            style: style.copyWith(
              color: style.color?.withValues(alpha: 0.5),
            ),
          ),
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
              color: AppColors.accentForeground,
            ),
            const SizedBox(width: 4),
            Text(
              compactMetric(video.likes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ],
        ),
      );
    }

    if (video.views.isNotEmpty) {
      separator();
      parts.add(
        Flexible(
          child: _IconText(
            Icons.visibility_outlined,
            compactMetric(video.views),
            style,
          ),
        ),
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
