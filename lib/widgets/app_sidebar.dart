import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../tv_focusable.dart';

enum SidebarItem { home, search, favorites }

/// Height reserved at the bottom for the floating bar on phones.
const double kBottomBarHeight = 84;

/// Design-canvas width reserved at the right edge for the floating sidebar.
/// Content that must stay fully visible (cards, titles) pads itself by this
/// much; full-bleed artwork (the hero) simply continues underneath.
const double kSidebarWidth = 104;

/// Slim, always-visible navigation rail: Home, Search, Favorites. Nothing else.
///
/// It floats *over* the page as a translucent glass pill instead of owning a
/// column of its own, so artwork behind it stays visible. The blue mark always
/// shows where the viewer is: Home, Search (while the search is open) or
/// Favorites.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.homeNode,
    required this.searchNode,
    required this.favoritesNode,
  });

  final SidebarItem selected;
  final ValueChanged<SidebarItem> onSelect;
  final FocusNode homeNode;
  final FocusNode searchNode;
  final FocusNode favoritesNode;

  @override
  Widget build(BuildContext context) {
    final phone = context.isPhone;
    final gap = context.s(Gaps.sm + 4);
    final buttons = <Widget>[
      _SidebarButton(
        icon: Icons.home_rounded,
        label: 'Home',
        active: selected == SidebarItem.home,
        focusNode: homeNode,
        onTap: () => onSelect(SidebarItem.home),
      ),
      phone ? SizedBox(width: gap) : SizedBox(height: gap),
      _SidebarButton(
        icon: Icons.search_rounded,
        label: 'Search',
        active: selected == SidebarItem.search,
        focusNode: searchNode,
        onTap: () => onSelect(SidebarItem.search),
      ),
      phone ? SizedBox(width: gap) : SizedBox(height: gap),
      _SidebarButton(
        icon: Icons.star_rounded,
        label: 'Favorites',
        active: selected == SidebarItem.favorites,
        focusNode: favoritesNode,
        onTap: () => onSelect(SidebarItem.favorites),
      ),
    ];

    final pill = DecoratedBox(
      decoration: BoxDecoration(
        // Translucent (no blur: blurring a scrolling page every frame is too
        // heavy for weak devices) so the images show through.
        color: AppColors.surface.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(context.s(34)),
        border: Border.all(color: const Color(0x33FFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 18),
        ],
      ),
      child: Padding(
        padding: phone
            ? EdgeInsets.symmetric(
                horizontal: context.s(14),
                vertical: context.s(10),
              )
            : EdgeInsets.symmetric(
                horizontal: context.s(10),
                vertical: context.s(14),
              ),
        child: phone
            ? Row(mainAxisSize: MainAxisSize.min, children: buttons)
            : Column(mainAxisSize: MainAxisSize.min, children: buttons),
      ),
    );

    // Phone: floating bar at the bottom, above the home indicator.
    if (phone) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: context.safe.bottom > 0 ? context.safe.bottom : 12,
        ),
        child: Align(alignment: Alignment.bottomCenter, child: pill),
      );
    }

    return SizedBox(
      width: context.s(kSidebarWidth),
      child: Align(
        alignment: const Alignment(1, -0.15),
        child: Padding(
          padding: EdgeInsets.only(right: context.s(14)),
          child: pill,
        ),
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.focusNode,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      onTap: onTap,
      scale: 1.06,
      scrollAlignment: null,
      semanticLabel: label,
      builder: (context, focused) {
        final Color background = focused
            ? AppColors.textPrimary
            : (active ? const Color(0xFF1B2B4D) : Colors.transparent);
        final Color foreground = focused
            ? AppColors.background
            : (active ? const Color(0xFF4C93FF) : AppColors.textSecondary);
        return AnimatedContainer(
          duration: Motion.quick,
          width: context.s(60),
          height: context.s(60),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(context.s(20)),
          ),
          child: Icon(icon, size: context.s(32), color: foreground),
        );
      },
    );
  }
}
