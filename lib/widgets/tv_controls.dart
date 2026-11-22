import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../models.dart';
import 'video_artwork.dart';

/// A large, remote-friendly surface. Directional keys are left to Flutter's
/// focus traversal; Select/Enter activates the current item exactly once.
class TvFocusSurface extends StatefulWidget {
  const TvFocusSurface({
    super.key,
    required this.onPressed,
    required this.child,
    this.onBookmark,
    this.autofocus = false,
    this.backgroundColor,
    this.focusedColor,
    this.borderRadius = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    this.minWidth,
    this.minHeight,
    this.expand = false,
    this.focusBorderWidth = 2.5,
  });

  final VoidCallback onPressed;
  final VoidCallback? onBookmark;
  final Widget child;
  final bool autofocus;
  final Color? backgroundColor;
  final Color? focusedColor;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double? minWidth;
  final double? minHeight;
  final bool expand;
  final double focusBorderWidth;

  @override
  State<TvFocusSurface> createState() => _TvFocusSurfaceState();
}

class _TvFocusSurfaceState extends State<TvFocusSurface> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'VXTUBE TV control');
  bool _focused = false;

  bool _isActivationKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.browserFavorites &&
        widget.onBookmark != null) {
      if (event is KeyDownEvent) widget.onBookmark!();
      return KeyEventResult.handled;
    }
    if (_isActivationKey(event.logicalKey)) {
      if (event is KeyDownEvent) widget.onPressed();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowUp => TraversalDirection.up,
        LogicalKeyboardKey.arrowDown => TraversalDirection.down,
        LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
        LogicalKeyboardKey.arrowRight => TraversalDirection.right,
        _ => null,
      };
      if (direction != null && node.focusInDirection(direction)) {
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        if (mounted && value != _focused) setState(() => _focused = value);
      },
      onKeyEvent: _onKey,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        constraints: BoxConstraints(
          minWidth: widget.minWidth ?? 0,
          minHeight: widget.minHeight ?? 0,
        ),
        decoration: BoxDecoration(
          color: _focused
              ? (widget.focusedColor ?? AppColors.accentStrong.withValues(alpha: 0.22))
              : (widget.backgroundColor ?? const Color(0xCC20232B)),
          borderRadius: radius,
          border: Border.all(
            color: _focused ? const Color(0xFFF7F8FF) : Colors.white12,
            width: _focused ? widget.focusBorderWidth : 1,
          ),
          boxShadow: _focused
              ? <BoxShadow>[
                  BoxShadow(
                    color: AppColors.accentBlue.withValues(alpha: 0.38),
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Padding(
            padding: widget.padding,
            child: widget.expand
                ? SizedBox(width: double.infinity, child: widget.child)
                : widget.child,
          ),
        ),
      ),
    );
  }
}

class TvNavigationRail extends StatelessWidget {
  const TvNavigationRail({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.isEnabled,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final bool Function(int index) isEnabled;

  static const List<({IconData icon, String label})> _items = <({IconData icon, String label})>[
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.search_rounded, label: 'Search'),
    (icon: Icons.video_library_outlined, label: 'Reels'),
    (icon: Icons.bookmarks_outlined, label: 'Library'),
    (icon: Icons.settings_outlined, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final visibleIndices = <int>[
      for (var index = 0; index < _items.length; index++)
        if (isEnabled(index)) index,
    ];
    return Container(
      width: 124,
      color: const Color(0xFF090B10),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 20),
            const Text.rich(
              TextSpan(children: <InlineSpan>[
                TextSpan(text: 'VX', style: TextStyle(color: Colors.white)),
                TextSpan(text: 'TUBE', style: TextStyle(color: Color(0xFF65A5FF))),
              ]),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: -0.7),
            ),
            const SizedBox(height: 26),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                itemCount: visibleIndices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 14),
                itemBuilder: (context, visibleIndex) {
                    final index = visibleIndices[visibleIndex];
                    final item = _items[index];
                    return TvFocusSurface(
                        key: ValueKey<String>('tv-nav-$index'),
                        onPressed: () => onSelect(index),
                        backgroundColor: selected == index
                            ? const Color(0xFF143B75)
                            : Colors.transparent,
                        focusedColor: const Color(0xFF1B4A91),
                        borderRadius: 15,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        minHeight: 76,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(item.icon, color: Colors.white, size: 28),
                            const SizedBox(height: 5),
                            Text(
                              item.label,
                              maxLines: 1,
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      );
                },
              ),
            ),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }
}

class TvVideoCard extends StatelessWidget {
  const TvVideoCard({
    super.key,
    required this.video,
    required this.onPressed,
    this.onBookmark,
    this.autofocus = false,
    this.width = 238,
  });

  final Video video;
  final VoidCallback onPressed;
  final VoidCallback? onBookmark;
  final bool autofocus;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TvFocusSurface(
        onPressed: onPressed,
        onBookmark: onBookmark,
        autofocus: autofocus,
        backgroundColor: const Color(0xFF151922),
        padding: const EdgeInsets.all(7),
        borderRadius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: VideoArtwork(video: video, showLabel: false),
                  ),
                  if (video.duration.isNotEmpty)
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.78),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: Text(
                            video.duration,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              <String>[if (video.views.isNotEmpty) '${video.views} views', if (video.date.isNotEmpty) video.date].join('  •  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB7BBC5), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
