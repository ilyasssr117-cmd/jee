import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../tv_focusable.dart';

enum TvButtonStyle { primary, secondary }

/// Large, remote-friendly button. Border width is constant so focus never
/// changes the layout; focus inverts the colours (white fill, dark label).
class TvButton extends StatelessWidget {
  const TvButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = TvButtonStyle.primary,
    this.autofocus = false,
    this.focusNode,
    this.onFocus,
    this.loading = false,
    this.scrollAlignment = 0.4,
    this.iconColor,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final TvButtonStyle style;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final bool loading;
  final double? scrollAlignment;

  /// Optional icon colour while the button is not focused (e.g. gold star).
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onFocus: onFocus,
      scrollAlignment: scrollAlignment,
      semanticLabel: label,
      // Ignore taps while busy so a slow request can't be started twice.
      onTap: loading ? () {} : onPressed,
      builder: (context, focused) {
        final primary = style == TvButtonStyle.primary;
        final Color background = focused
            ? AppColors.textPrimary
            : (primary ? AppColors.accentStrong : AppColors.surfaceHigh);
        final Color foreground =
            focused ? AppColors.background : AppColors.textPrimary;
        final Color border = focused
            ? AppColors.textPrimary
            : (primary ? Colors.transparent : AppColors.outline);

        return AnimatedContainer(
          duration: Motion.quick,
          constraints: BoxConstraints(minHeight: context.s(52)),
          padding: EdgeInsets.symmetric(
            horizontal: context.s(24),
            vertical: context.s(12),
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(context.s(Radii.button)),
            border: Border.all(color: border, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                SizedBox(
                  width: context.s(22),
                  height: context.s(22),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: foreground,
                  ),
                )
              else if (icon != null)
                Icon(
                  icon,
                  size: context.s(26),
                  color: focused ? foreground : (iconColor ?? foreground),
                ),
              if (loading || icon != null) SizedBox(width: context.s(10)),
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
        );
      },
    );
  }
}

/// Pill-shaped filter chip (categories).
class TvChip extends StatelessWidget {
  const TvChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      scale: 1.06,
      scrollAlignment: 0.3,
      semanticLabel: selected ? '$label, selected' : label,
      onTap: onPressed,
      builder: (context, focused) {
        final Color background = focused
            ? AppColors.textPrimary
            : (selected ? AppColors.accentStrong : AppColors.surfaceHigh);
        final Color foreground =
            focused ? AppColors.background : AppColors.textPrimary;

        return AnimatedContainer(
          duration: Motion.quick,
          height: context.s(44),
          padding: EdgeInsets.symmetric(horizontal: context.s(22)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(context.s(Radii.pill)),
            border: Border.all(
              color: focused || selected ? Colors.transparent : AppColors.outline,
              width: 1.5,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label.copyWith(
              fontSize: 16,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: foreground,
            ),
          ),
        );
      },
    );
  }
}
