import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';

enum AppTab { home, search, reels, library, settings }

const double kBottomBarHeight = 74;

double appDockHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
  final lines = scale > 1.65 ? 2 : 1;
  final labelHeight = 11 * scale * 1.1 * lines;
  return math.max(66, 42 + labelHeight).toDouble();
}

double appBottomBarHeight(BuildContext context) =>
    math.max(kBottomBarHeight, appDockHeight(context) + 8).toDouble();

class AppBottomBar extends StatefulWidget {
  const AppBottomBar({
    super.key,
    required this.selected,
    required this.onSelect,
    this.bottomGap,
    this.isTabEnabled,
  });

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;
  final double? bottomGap;
  final bool Function(AppTab tab)? isTabEnabled;

  @override
  State<AppBottomBar> createState() => _AppBottomBarState();
}

class _AppBottomBarState extends State<AppBottomBar> {
  static const List<({AppTab tab, IconData icon, String label})> _tabs = [
    (tab: AppTab.home, icon: CupertinoIcons.house_fill, label: 'Home'),
    (tab: AppTab.search, icon: CupertinoIcons.search, label: 'Search'),
    (
      tab: AppTab.reels,
      icon: CupertinoIcons.play_rectangle_fill,
      label: 'Reels'
    ),
    (
      tab: AppTab.library,
      icon: CupertinoIcons.rectangle_stack_fill,
      label: 'Library'
    ),
    (
      tab: AppTab.settings,
      icon: CupertinoIcons.slider_horizontal_3,
      label: 'Settings'
    ),
  ];

  final GlobalKey _barKey = GlobalKey();
  final Map<AppTab, GlobalKey> _tabKeys = {
    for (final tab in AppTab.values) tab: GlobalKey(),
  };

  bool _dragging = false;
  AppTab? _hovered;
  double? _dragIndicatorLeft;

  AppTab get _indicatorTab =>
      _dragging ? (_hovered ?? widget.selected) : widget.selected;

  List<({AppTab tab, IconData icon, String label})> get _visibleTabs => _tabs
      .where((item) => widget.isTabEnabled?.call(item.tab) ?? true)
      .toList();

  void _beginDrag(AppTab tab) {
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    final tabBox =
        _tabKeys[tab]?.currentContext?.findRenderObject() as RenderBox?;
    double? startLeft;
    if (bar != null && bar.hasSize && tabBox != null && tabBox.hasSize) {
      final tabCenter = tabBox.localToGlobal(
        Offset(tabBox.size.width / 2, tabBox.size.height / 2),
      );
      final localCenter = bar.globalToLocal(tabCenter);
      final tabs = _visibleTabs;
      if (tabs.isEmpty) return;
      final itemWidth = bar.size.width / tabs.length;
      startLeft = (localCenter.dx - itemWidth / 2)
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
    final tabs = _visibleTabs;
    if (tabs.isEmpty) return;
    final itemWidth = bar.size.width / tabs.length;
    final index =
        (local.dx / itemWidth).floor().clamp(0, tabs.length - 1).toInt();
    final next = tabs[index].tab;
    final nextLeft = (local.dx - itemWidth / 2)
        .clamp(0.0, bar.size.width - itemWidth)
        .toDouble();
    final changedTab = next != _hovered;
    if (changedTab) Haptics.play(Haptic.selection);
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
    final width =
        math.min(MediaQuery.sizeOf(context).width - 20, 420.0).toDouble();
    final dockHeight = appDockHeight(context);
    final tabs = _visibleTabs;
    if (tabs.isEmpty) return const SizedBox.shrink();

    // Scaffold gives bottomNavigationBar a loose height constraint. A bare
    // Center expands to that maximum and makes the dock appear mid-screen.
    // Keep this slot explicitly bounded and pin the glass dock to its bottom.
    return SizedBox(
      height: dockHeight + bottom,
      width: double.infinity,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(27),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                width: width,
                height: dockHeight,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.palette.brightness == Brightness.dark
                      ? const Color(0xD21A2040)
                      : const Color(0xE8F5F6F8),
                  borderRadius: BorderRadius.circular(27),
                  border: Border.all(
                    color: AppColors.outline,
                    width: 0.7,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final itemWidth = constraints.maxWidth / tabs.length;
                    final selectedLeft = tabs
                            .indexWhere((item) => item.tab == _indicatorTab)
                            .clamp(0, tabs.length - 1) *
                        itemWidth;
                    final indicatorLeft = _dragging
                        ? (_dragIndicatorLeft ?? selectedLeft)
                        : selectedLeft;
                    return SizedBox(
                      key: _barKey,
                      height: dockHeight - 10,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (_dragging)
                            Positioned(
                              left: indicatorLeft,
                              top: 0,
                              bottom: 0,
                              width: itemWidth,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 2),
                                child: _GlassIndicator(),
                              ),
                            )
                          else
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 230),
                              curve: Curves.easeOutCubic,
                              left: indicatorLeft,
                              top: 0,
                              bottom: 0,
                              width: itemWidth,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 2),
                                child: _GlassIndicator(),
                              ),
                            ),
                          Row(
                            children: [
                              for (final item in tabs)
                                SizedBox(
                                  key: _tabKeys[item.tab],
                                  width: itemWidth,
                                  child: _TabItem(
                                    icon: item.icon,
                                    label: item.label,
                                    active: _indicatorTab == item.tab,
                                    onTap: () {
                                      Haptics.play(Haptic.selection);
                                      widget.onSelect(item.tab);
                                    },
                                    onLongPressStart: () =>
                                        _beginDrag(item.tab),
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
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassIndicator extends StatelessWidget {
  const _GlassIndicator();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.palette.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.065)
              : AppColors.accentSoft.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(17),
        ),
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
    required this.onLongPressStart,
    required this.onLongPressMove,
    required this.onLongPressEnd,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final ValueChanged<Offset> onLongPressMove;
  final VoidCallback onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accentStrong : AppColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (_) => onLongPressStart(),
      onLongPressMoveUpdate: (details) =>
          onLongPressMove(details.globalPosition),
      onLongPressEnd: (_) => onLongPressEnd(),
      child: SizedBox(
        height: appDockHeight(context) - 10,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: active ? 1.08 : 1,
              duration: Motion.quick,
              curve: Motion.curve,
              child: SizedBox(
                width: 28,
                height: 26,
                child: Center(child: Icon(icon, size: 21, color: color)),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: Motion.quick,
              curve: Motion.curve,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.1,
                color: active ? AppColors.textPrimary : AppColors.textTertiary,
              ),
              child: Text(
                _accessibleLabel(
                  label,
                  MediaQuery.textScalerOf(context).scale(11) / 11,
                ),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _accessibleLabel(String value, double scale) {
    if (scale <= 1.65) return value;
    return switch (value) {
      'Home' => 'Ho\nme',
      'Search' => 'Sea\nrch',
      'Reels' => 'Re\nels',
      'Library' => 'Lib\nrary',
      'Settings' => 'Set\ntings',
      _ => value,
    };
  }
}
