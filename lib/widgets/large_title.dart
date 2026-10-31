import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Native iOS collapsing navigation bar: a 34pt Large Title that scrolls away
/// while a centered 17pt inline title fades in over a blurred, hairline-ruled
/// bar (UINavigationBar with `prefersLargeTitles`).
class LargeTitleSliver extends StatelessWidget {
  const LargeTitleSliver({super.key, required this.title, this.trailing});

  final String title;

  /// Optional trailing bar button (e.g. "Clear").
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _LargeTitleDelegate(
        title: title,
        trailing: trailing,
        topPadding: context.safe.top,
        margin: context.hMargin,
        background: AppColors.background,
        outline: AppColors.outline,
        textColor: AppColors.textPrimary,
        brightness: AppColors.palette.brightness,
      ),
    );
  }
}

class _LargeTitleDelegate extends SliverPersistentHeaderDelegate {
  _LargeTitleDelegate({
    required this.title,
    required this.trailing,
    required this.topPadding,
    required this.margin,
    required this.background,
    required this.outline,
    required this.textColor,
    required this.brightness,
  });

  static const double _bar = 44;
  static const double _large = 52;

  final String title;
  final Widget? trailing;
  final double topPadding;
  final double margin;
  final Color background;
  final Color outline;
  final Color textColor;
  final Brightness brightness;

  @override
  double get minExtent => topPadding + _bar;

  @override
  double get maxExtent => topPadding + _bar + _large;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final t = (shrinkOffset / _large).clamp(0.0, 1.0).toDouble();
    // The inline title appears only once the large one has nearly left.
    final inline = ((t - 0.6) / 0.4).clamp(0.0, 1.0).toDouble();
    final barVisible = t > 0.02;

    final bar = Stack(
      fit: StackFit.expand,
      children: [
        if (barVisible)
          Opacity(
            opacity: inline,
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: background.withValues(alpha: 0.78),
                    border: Border(
                      bottom: BorderSide(color: outline, width: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: topPadding,
          height: _bar,
          child: Opacity(
            opacity: inline,
            child: Center(
              child: Text(
                title,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.41,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
        if (trailing != null)
          Positioned(
            right: margin,
            top: topPadding,
            height: _bar,
            child: Center(child: trailing),
          ),
        Positioned(
          left: margin,
          right: margin,
          bottom: 4,
          child: Opacity(
            opacity: (1 - t * 1.6).clamp(0.0, 1.0).toDouble(),
            child: Transform.scale(
              scale: 1 + (-shrinkOffset).clamp(0.0, 40.0) / 400,
              alignment: Alignment.bottomLeft,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 34,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.37,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return bar;
  }

  @override
  bool shouldRebuild(covariant _LargeTitleDelegate old) =>
      title != old.title ||
      trailing != old.trailing ||
      topPadding != old.topPadding ||
      margin != old.margin ||
      background != old.background ||
      brightness != old.brightness;
}
