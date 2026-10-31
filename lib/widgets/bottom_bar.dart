import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppTab { home, search, reels, library, settings }

const double kBottomBarHeight = 78;

/// Height of the floating glass capsule (iOS 26 tab bar is 62pt tall).
const double _kCapsuleHeight = 62;

/// iOS 26 style tab bar: a floating glass capsule with the main tabs and a
/// detached circular Search button on the trailing side (the `.search` role
/// tab). Press-and-hold then drag across the capsule scrubs between tabs
/// with a selection haptic on every tab crossing, like the system bar.
class AppBottomBar extends StatefulWidget {
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
  State<AppBottomBar> createState() => _AppBottomBarState();
}

typedef _TabSpec = ({
  AppTab tab,
  IconData icon,
  IconData activeIcon,
  String label,
});

class _AppBottomBarState extends State<AppBottomBar> {
  static const List<_TabSpec> _tabs = [
    (
      tab: AppTab.home,
      icon: CupertinoIcons.house,
      activeIcon: CupertinoIcons.house_fill,
      label: 'Home',
    ),
    (
      tab: AppTab.reels,
      icon: CupertinoIcons.play_rectangle,
      activeIcon: CupertinoIcons.play_rectangle_fill,
      label: 'Reels',
    ),
    (
      tab: AppTab.library,
      icon: CupertinoIcons.square_stack,
      activeIcon: CupertinoIcons.square_stack_fill,
      label: 'Library',
    ),
    (
      tab: AppTab.settings,
      icon: CupertinoIcons.gear_alt,
      activeIcon: CupertinoIcons.gear_alt_fill,
      label: 'Settings',
    ),
  ];

  final GlobalKey _barKey = GlobalKey();

  bool _dragging = false;
  AppTab? _hovered;
  double? _dragIndicatorLeft;

  bool get _searchActive => widget.selected == AppTab.search;

  /// The tab whose pill is highlighted right now (null while Search is active).
  AppTab? get _indicatorTab {
    if (_dragging) return _hovered ?? widget.selected;
    return _searchActive ? null : widget.selected;
  }

  int _indexOf(AppTab tab) => _tabs.indexWhere((item) => item.tab == tab);

  void _beginDrag(AppTab tab) {
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    double? startLeft;
    if (bar != null && bar.hasSize) {
      final itemWidth = bar.size.width / _tabs.length;
      startLeft = (_indexOf(tab) * itemWidth)
          .clamp(0.0, bar.size.width - itemWidth)
          .toDouble();
    }
    setState(() {
      _dragging = true;
      _hovered = tab;
      _dragIndicatorLeft = startLeft;
    });
    Haptics.play(Haptic.medium);
  }

  void _updateDrag(Offset globalPosition) {
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (bar == null || !bar.hasSize) return;
    final local = bar.globalToLocal(globalPosition);
    final itemWidth = bar.size.width / _tabs.length;
    final index =
        (local.dx / itemWidth).floor().clamp(0, _tabs.length - 1).toInt();
    final next = _tabs[index].tab;
    final nextLeft = (local.dx - itemWidth / 2)
        .clamp(0.0, bar.size.width - itemWidth)
        .toDouble();
    if (next != _hovered) Haptics.play(Haptic.selection);
    setState(() {
      _hovered = next;
      _dragIndicatorLeft = nextLeft;
    });
  }

  void _finishDrag() {
    final target = _hovered;
    setState(() {
      _dragging = false;
      _hovered = null;
      _dragIndicatorLeft = null;
    });
    if (target != null && target != widget.selected) {
      Haptics.play(Haptic.light);
      widget.onSelect(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom =
        widget.bottomGap ?? math.max(context.safe.bottom - 4, 10.0).toDouble();
    final maxWidth = math.min(MediaQuery.sizeOf(context).width - 24, 480.0);

    // Scaffold gives bottomNavigationBar a loose height constraint, so this
    // slot is explicitly bounded and the glass is pinned to its bottom.
    return SizedBox(
      height: kBottomBarHeight + bottom,
      width: double.infinity,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottom + 6),
          child: SizedBox(
            width: maxWidth,
            height: _kCapsuleHeight,
            child: Row(
              children: [
                Expanded(child: _buildCapsule()),
                const SizedBox(width: 10),
                _SearchButton(
                  active: _searchActive,
                  onTap: () {
                    Haptics.play(Haptic.selection);
                    widget.onSelect(AppTab.search);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCapsule() {
    return _Glass(
      radius: _kCapsuleHeight / 2,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / _tabs.length;
            final indicator = _indicatorTab;
            final selectedLeft =
                indicator == null ? 0.0 : _indexOf(indicator) * itemWidth;
            final indicatorLeft = _dragging
                ? (_dragIndicatorLeft ?? selectedLeft)
                : selectedLeft;
            final pill = Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _GlassPill(lifted: _dragging),
            );
            return SizedBox(
              key: _barKey,
              height: _kCapsuleHeight - 8,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (indicator != null)
                    if (_dragging)
                      Positioned(
                        left: indicatorLeft,
                        top: 0,
                        bottom: 0,
                        width: itemWidth,
                        child: pill,
                      )
                    else
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutBack,
                        left: indicatorLeft,
                        top: 0,
                        bottom: 0,
                        width: itemWidth,
                        child: pill,
                      ),
                  Row(
                    children: [
                      for (final item in _tabs)
                        SizedBox(
                          width: itemWidth,
                          child: _TabItem(
                            icon: item.icon,
                            activeIcon: item.activeIcon,
                            label: item.label,
                            active: _indicatorTab == item.tab,
                            onTap: () {
                              Haptics.play(Haptic.selection);
                              widget.onSelect(item.tab);
                            },
                            onLongPressStart: () => _beginDrag(item.tab),
                            onLongPressMove: _updateDrag,
                            onLongPressEnd: _finishDrag,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

bool _isDark() => AppColors.palette.brightness == Brightness.dark;

/// Translucent blurred "liquid glass" surface with a specular hairline.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark();
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.38 : 0.14),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [Color(0xA62C2C2E), Color(0x991C1C1E)]
                    : const [Color(0xB3FFFFFF), Color(0xA6F2F2F7)],
              ),
              border: Border.all(
                color: dark ? const Color(0x2EFFFFFF) : const Color(0x99FFFFFF),
                width: 0.6,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.lifted});

  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final dark = _isDark();
    return AnimatedScale(
      scale: lifted ? 1.1 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_kCapsuleHeight),
          color: dark
              ? Colors.white.withValues(alpha: lifted ? 0.20 : 0.14)
              : Colors.black.withValues(alpha: lifted ? 0.10 : 0.07),
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? 0.10 : 0.55),
            width: 0.6,
          ),
        ),
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: 'Search',
      haptic: Haptic.none,
      pressedScale: 0.92,
      onTap: onTap,
      child: SizedBox(
        width: _kCapsuleHeight,
        height: _kCapsuleHeight,
        child: _Glass(
          radius: _kCapsuleHeight / 2,
          child: Center(
            child: AnimatedScale(
              scale: active ? 1.08 : 1,
              duration: Motion.normal,
              curve: Curves.easeOutBack,
              child: Icon(
                CupertinoIcons.search,
                size: 24,
                color: active ? AppColors.accent : AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressMove,
    required this.onLongPressEnd,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final ValueChanged<Offset> onLongPressMove;
  final VoidCallback onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (_) => onLongPressStart(),
      onLongPressMoveUpdate: (details) => onLongPressMove(details.globalPosition),
      onLongPressEnd: (_) => onLongPressEnd(),
      child: SizedBox(
        height: _kCapsuleHeight - 8,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 28,
              child: Center(
                child: Icon(active ? activeIcon : icon, size: 24, color: color),
              ),
            ),
            const SizedBox(height: 1),
            AnimatedDefaultTextStyle(
              duration: Motion.quick,
              curve: Motion.curve,
              style: TextStyle(
                fontSize: 10,
                height: 1.1,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.1,
                color: color,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.clip),
            ),
          ],
        ),
      ),
    );
  }
}
