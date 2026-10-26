import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppButtonStyle { primary, secondary }

/// Compact phone button (40 pt high).
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
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final AppButtonStyle style;
  final bool loading;

  /// Icon colour override (e.g. gold star).
  final Color? iconColor;

  /// Fill the available width instead of hugging the label.
  final bool expand;

  /// Sits on top of artwork / video: secondary buttons turn translucent white.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final primary = style == AppButtonStyle.primary;
    final Color foreground = primary || onDark
        ? Colors.white
        : AppColors.textPrimary;
    final Color background = primary
        ? AppColors.accentStrong
        : (onDark ? const Color(0x2EFFFFFF) : AppColors.surfaceHigh);
    final Color border = primary
        ? Colors.transparent
        : (onDark ? const Color(0x26FFFFFF) : AppColors.outline);
    return Pressable(
      semanticLabel: label,
      // Ignore taps while busy so a slow request can't be started twice.
      onTap: loading ? null : onPressed,
      child: AnimatedContainer(
        duration: Motion.quick,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(Radii.button),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              CupertinoActivityIndicator(radius: 8, color: foreground)
            else if (icon != null)
              Icon(
                icon,
                size: 18,
                color: iconColor ?? foreground,
              ),
            if (loading || icon != null) const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
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

/// Pill-shaped filter chip (categories), 32 pt high.
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

  /// Sits on a dark sheet / video: unselected chips are translucent white.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: selected ? '$label, selected' : label,
      haptic: Haptic.selection,
      pressedScale: 0.93,
      onTap: onPressed,
      child: AnimatedContainer(
        duration: Motion.normal,
        curve: Motion.curve,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentStrong
              : (onDark ? const Color(0x1FFFFFFF) : AppColors.surfaceHigh),
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : (onDark ? const Color(0x1FFFFFFF) : AppColors.outline),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.label.copyWith(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected || onDark ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Round icon button (back, close, player controls).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.label,
    this.size = 38,
    this.iconSize,
    this.background = const Color(0x8C000000),
    this.color = Colors.white,
    this.haptic = Haptic.light,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final double size;
  final double? iconSize;
  final Color background;
  final Color color;
  final Haptic haptic;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: label,
      onTap: onTap,
      haptic: haptic,
      pressedScale: 0.88,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: background,
          border: Border.all(color: const Color(0x26FFFFFF)),
        ),
        child: Icon(icon, size: iconSize ?? size * 0.55, color: color),
      ),
    );
  }
}
