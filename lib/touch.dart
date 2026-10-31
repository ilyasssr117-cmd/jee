import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

enum Haptic { none, selection, light, medium, heavy }

abstract final class Haptics {
  static bool enabled = true;

  static void play(Haptic kind) {
    if (!enabled) return;
    switch (kind) {
      case Haptic.none:
        return;
      case Haptic.selection:
        HapticFeedback.selectionClick();
      case Haptic.light:
        HapticFeedback.lightImpact();
      case Haptic.medium:
        HapticFeedback.mediumImpact();
      case Haptic.heavy:
        HapticFeedback.heavyImpact();
    }
  }
}

class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.haptic = Haptic.light,
    this.longPressHaptic = Haptic.medium,
    this.pressedScale = 0.97,
    this.semanticLabel,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Haptic haptic;
  final Haptic longPressHaptic;
  final double pressedScale;
  final String? semanticLabel;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value || !mounted) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = AnimatedScale(
      scale: _down ? widget.pressedScale : 1,
      duration: _down ? const Duration(milliseconds: 90) : Motion.normal,
      curve: Motion.curve,
      child: widget.child,
    );

    if (widget.onTap == null && widget.onLongPress == null) return child;

    child = GestureDetector(
      behavior: widget.behavior,
      excludeFromSemantics: true,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: () => _set(false),
      onLongPressDown: widget.onLongPress == null ? null : (_) => _set(true),
      onLongPressCancel: () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              Haptics.play(widget.haptic);
              widget.onTap!();
            },
      onLongPressStart: widget.onLongPress == null
          ? null
          : (_) {
              _set(false);
              Haptics.play(widget.longPressHaptic);
              widget.onLongPress!();
            },
      child: child,
    );

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: child,
    );
  }
}
