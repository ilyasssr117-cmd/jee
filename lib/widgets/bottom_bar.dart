import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppTab { home, search, library, settings }

const double kBottomBarHeight = 76;

class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.selected,
    required this.onSelect,
    this.bottomGap,
  });

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  final double? bottomGap;

  @override
  Widget build(BuildContext context) {
    final bottom = bottomGap ?? math.max(context.safe.bottom - 4, 10.0);
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0x2EFFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 16),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TabItem(
              icon: Icons.home_rounded,
              label: 'Home',
              active: selected == AppTab.home,
              onTap: () => onSelect(AppTab.home),
            ),
            _TabItem(
              icon: Icons.search_rounded,
              label: 'Search',
              active: selected == AppTab.search,
              onTap: () => onSelect(AppTab.search),
            ),
            _TabItem(
              icon: Icons.video_library_rounded,
              label: 'Library',
              active: selected == AppTab.library,
              onTap: () => onSelect(AppTab.library),
            ),
            _TabItem(
              icon: Icons.tune_rounded,
              label: 'Settings',
              active: selected == AppTab.settings,
              onTap: () => onSelect(AppTab.settings),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [pill],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: label,
      haptic: Haptic.selection,
      pressedScale: 0.9,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.normal,
        curve: Motion.curve,
        width: 58,
        height: 42,
        decoration: BoxDecoration(
          color: active ? AppColors.blueSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(21),
        ),
        child: Icon(
          icon,
          size: 24,
          color: active ? AppColors.blue : AppColors.textSecondary,
        ),
      ),
    );
  }
}
