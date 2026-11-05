import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppButtonStyle { primary, secondary, tertiary }

double appChipTapHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
  return math.max(44, math.max(36, 24 + 12 * scale)).toDouble();
}

double appButtonRequiredWidth(
  BuildContext context, {
  required String label,
  bool hasIcon = true,
  AppButtonStyle style = AppButtonStyle.tertiary,
}) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: AppText.label),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final horizontalPadding = style == AppButtonStyle.tertiary ? 20.0 : 34.0;
  final iconAndGap = hasIcon ? 26.0 : 0.0;
  return painter.width + horizontalPadding + iconAndGap + 2;
}

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = AppButtonStyle.primary,
    this.loading = false,
    this.iconColor,
    this.expand = false,
    this.onDark = false,
    this.semanticLabel,
    this.singleLine = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final AppButtonStyle style;
  final bool loading;

  final Color? iconColor;

  final bool expand;

  final bool onDark;

  final String? semanticLabel;

  /// Keeps short action labels on one line when the button shares a row.
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
    final primary = style == AppButtonStyle.primary;
    final tertiary = style == AppButtonStyle.tertiary;
    final Color foreground =
        primary || onDark ? Colors.white : AppColors.textPrimary;
    const desktopOnDarkBackground = Color(0xFF252A3A);
    const desktopOnDarkOutline = Color(0xFF454B64);
    final Color background = primary
        ? AppColors.accentStrong
        : (tertiary
            ? (windowsDesktop
                ? (onDark ? desktopOnDarkBackground : AppColors.surfaceHigh)
                : Colors.transparent)
            : (onDark && !windowsDesktop
                ? const Color(0x2EFFFFFF)
                : onDark
                    ? desktopOnDarkBackground
                    : AppColors.surfaceHigh));
    final Color border = primary
        ? Colors.transparent
        : (tertiary
            ? (windowsDesktop
                ? (onDark ? desktopOnDarkOutline : AppColors.outline)
                : Colors.transparent)
            : (onDark && !windowsDesktop
                ? const Color(0x26FFFFFF)
                : onDark
                    ? desktopOnDarkOutline
                    : AppColors.outline));
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Pressable(
      semanticLabel: semanticLabel ?? label,
      onTap: loading ? null : onPressed,
      child: AnimatedContainer(
        duration: Motion.quick,
        constraints: BoxConstraints(minHeight: math.max(46, 44 * textScale)),
        padding: EdgeInsets.symmetric(
          horizontal: tertiary ? 10 : 17,
          vertical: textScale > 1.2 ? 7 : 0,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(Radii.button),
          border: Border.all(color: border),
          boxShadow: const [],
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              CupertinoActivityIndicator(radius: 8, color: foreground)
            else if (icon != null)
              Icon(icon, size: 20, color: iconColor ?? foreground),
            if ((loading || icon != null) && label.isNotEmpty)
              const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: singleLine ? 1 : 2,
                softWrap: !singleLine,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.onDark = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final chipHeight = math.max(36, 24 + 12 * scale).toDouble();
    final tapHeight = math.max(44, chipHeight).toDouble();
    return Pressable(
      semanticLabel: selected ? '$label, selected' : label,
      haptic: Haptic.selection,
      pressedScale: 0.93,
      onTap: onPressed,
      child: SizedBox(
        height: tapHeight,
        child: Center(
          child: AnimatedContainer(
            duration: Motion.normal,
            curve: Motion.curve,
            height: chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accentStrong
                  : (onDark && !windowsDesktop
                      ? const Color(0x1FFFFFFF)
                      : onDark
                          ? const Color(0xFF252A3A)
                          : AppColors.surfaceHigh),
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : (onDark && !windowsDesktop
                        ? const Color(0x1FFFFFFF)
                        : onDark
                            ? const Color(0xFF454B64)
                            : AppColors.outline),
              ),
            ),
            child: Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color:
                    selected || onDark ? Colors.white : AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const double kMinTapSize = 44;

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.label,
    this.size = 38,
    this.tapSize = 0,
    this.iconSize,
    this.background = const Color(0x8C000000),
    this.color = Colors.white,
    this.haptic = Haptic.light,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final double size;

  final double tapSize;
  final double? iconSize;
  final Color background;
  final Color color;
  final Haptic haptic;

  @override
  Widget build(BuildContext context) {
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
    final box = math.max(size, tapSize);
    return Pressable(
      semanticLabel: label,
      onTap: onTap,
      haptic: haptic,
      pressedScale: 0.88,
      child: SizedBox(
        width: box,
        height: box,
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: windowsDesktop ? const Color(0xFF252A3A) : background,
              border: Border.all(color: const Color(0x26FFFFFF)),
            ),
            child: Icon(icon, size: iconSize ?? 22, color: color),
          ),
        ),
      ),
    );
  }
}

class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(-3, -3),
      child: RoundIconButton(
        icon: Icons.arrow_back_ios_new_rounded,
        iconSize: 20,
        tapSize: kMinTapSize,
        label: 'Back',
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
