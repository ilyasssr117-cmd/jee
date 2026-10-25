import 'package:flutter/material.dart';

import 'app_button.dart';

/// Round "back" button for pages opened on top of the home screen.
class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key, this.onPressed});

  /// Defaults to popping the current route.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return RoundIconButton(
      icon: Icons.arrow_back_ios_new_rounded,
      iconSize: 18,
      label: 'Back',
      onTap: onPressed ?? () => Navigator.of(context).maybePop(),
    );
  }
}
