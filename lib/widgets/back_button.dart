import 'package:flutter/material.dart';

import 'app_button.dart';

class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(-3, -3),
      child: RoundIconButton(
        icon: Icons.arrow_back_ios_new_rounded,
        iconSize: 18,
        tapSize: kMinTapSize,
        label: 'Back',
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
