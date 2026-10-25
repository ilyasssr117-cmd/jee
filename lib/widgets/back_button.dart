import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../tv_focusable.dart';

/// Round "back" button for pages opened on top of the home screen. Works with
/// touch (iPhone / iPad) and with the TV remote (focus + OK).
class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key, this.onPressed, this.focusNode});

  /// Defaults to popping the current route.
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final size = context.s(52).clamp(44.0, 80.0).toDouble();
    return TvFocusable(
      focusNode: focusNode,
      scale: 1.1,
      scrollAlignment: null,
      semanticLabel: 'Back',
      onTap: onPressed ?? () => Navigator.of(context).maybePop(),
      builder: (context, focused) => AnimatedContainer(
        duration: Motion.quick,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused ? AppColors.textPrimary : const Color(0x99000000),
          border: Border.all(
            color: focused ? AppColors.textPrimary : const Color(0x33FFFFFF),
            width: 2,
          ),
        ),
        child: Icon(
          Icons.arrow_back_rounded,
          size: size * 0.55,
          color: focused ? AppColors.background : AppColors.textPrimary,
        ),
      ),
    );
  }
}
