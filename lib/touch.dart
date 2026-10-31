import 'package:flutter/gestures.dart';
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
    this.pressedScale = 0.95,
    this.pressedOpacity = 1,
    this.longPressDuration = const Duration(milliseconds: 350),
    this.semanticLabel,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Haptic haptic;
  final Haptic longPressHaptic;
  final double pressedScale;

  /// iOS-style highlight: text buttons and list rows dim instead of shrinking.
  final double pressedOpacity;
  final Duration longPressDuration;
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
      child: widget.pressedOpacity >= 1
          ? widget.child
          : AnimatedOpacity(
              opacity: _down ? widget.pressedOpacity : 1,
              duration: _down ? const Duration(milliseconds: 60) : Motion.normal,
              child: widget.child,
            ),
    );

    if (widget.onTap == null && widget.onLongPress == null) return child;

    child = RawGestureDetector(
      behavior: widget.behavior,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(),
          (TapGestureRecognizer tap) {
            tap.onTapDown = (_) => _set(true);
            tap.onTapCancel = () => _set(false);
            tap.onTapUp = (_) => _set(false);
            tap.onTap = widget.onTap == null
                ? null
                : () {
                    Haptics.play(widget.haptic);
                    widget.onTap!();
                  };
          },
        ),
        if (widget.onLongPress != null)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: widget.longPressDuration,
            ),
            (LongPressGestureRecognizer press) {
              press.onLongPressStart = (_) {
                _set(false);
                Haptics.play(widget.longPressHaptic);
                widget.onLongPress!();
              };
            },
          ),
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
