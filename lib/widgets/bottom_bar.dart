import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppTab { home, search, history, favorites, settings }

/// Space reserved at the bottom for the compact floating iOS tab bar.
const double kBottomBarHeight = 72;

class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(context.safe.bottom - 4, 10.0);
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.outline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _barShadowOpacity),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
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
              icon: Icons.history_rounded,
              label: 'History',
              active: selected == AppTab.history,
              onTap: () => onSelect(AppTab.history),
            ),
            _TabItem(
              icon: Icons.bookmark_rounded,
              label: 'Saved',
              active: selected == AppTab.favorites,
              onTap: () => onSelect(AppTab.favorites),
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

const double _barShadowOpacity = 0.22;

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
      pressedScale: 0.92,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.normal,
        curve: Motion.curve,
        width: 56,
        height: 44,
        decoration: BoxDecoration(
          color: active ? AppColors.blueSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(21),
        ),
        child: Icon(
          icon,
          size: 22,
          color: active ? AppColors.blue : AppColors.textSecondary,
        ),
      ),
    );
  }
}
