import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppTab { home, search, reels, library, settings }

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
    final tabWidth = ((MediaQuery.sizeOf(context).width - 42) / 5)
        .clamp(48.0, 58.0)
        .toDouble();
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.outline),
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
              width: tabWidth,
              onTap: () => onSelect(AppTab.home),
            ),
            _TabItem(
              icon: Icons.search_rounded,
              label: 'Search',
              active: selected == AppTab.search,
              width: tabWidth,
              onTap: () => onSelect(AppTab.search),
            ),
            _TabItem(
              icon: Icons.smart_display_rounded,
              label: 'Reels',
              active: selected == AppTab.reels,
              width: tabWidth,
              onTap: () => onSelect(AppTab.reels),
            ),
            _TabItem(
              icon: Icons.video_library_rounded,
              label: 'Library',
              active: selected == AppTab.library,
              width: tabWidth,
              onTap: () => onSelect(AppTab.library),
            ),
            _TabItem(
              icon: Icons.tune_rounded,
              label: 'Settings',
              active: selected == AppTab.settings,
              width: tabWidth,
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
    required this.width,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final double width;
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
        width: width,
        height: 50,
        decoration: BoxDecoration(
          color: active ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: active ? 1.06 : 1,
              duration: Motion.normal,
              curve: Motion.curve,
              child: Icon(
                icon,
                size: 20,
                color: active
                    ? AppColors.accentStrong
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: Motion.normal,
              curve: Motion.curve,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.1,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? AppColors.accentStrong
                    : AppColors.textTertiary,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.clip),
            ),
          ],
        ),
      ),
    );
  }
}
