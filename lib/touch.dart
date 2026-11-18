import 'dart:async';

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
    this.autofocus = false,
    this.focusRadius = 16,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Haptic haptic;
  final Haptic longPressHaptic;
  final double pressedScale;
  final String? semanticLabel;
  final HitTestBehavior behavior;
  final bool autofocus;
  final double focusRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  static const Duration _remoteHold = Duration(milliseconds: 520);

  final FocusNode _focus = FocusNode(debugLabel: 'Pressable');
  bool _down = false;
  bool _focused = false;
  bool _holdFired = false;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _holdTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    if (mounted && _focused) setState(() {});
  }

  bool get _showRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _set(bool value) {
    if (_down == value || !mounted) return;
    setState(() => _down = value);
  }

  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_isSelect(event.logicalKey)) return KeyEventResult.ignored;
    if (widget.onTap == null && widget.onLongPress == null) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _holdFired = false;
      _holdTimer?.cancel();
      if (widget.onLongPress != null) {
        _holdTimer = Timer(_remoteHold, () {
          _holdFired = true;
          _set(false);
          Haptics.play(widget.longPressHaptic);
          widget.onLongPress?.call();
        });
      }
      _set(true);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _set(false);
      if (!_holdFired) {
        Haptics.play(widget.haptic);
        widget.onTap?.call();
      }
      _holdFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final ring = _showRing;
    Widget child = AnimatedScale(
      scale: _down && !reduceMotion
          ? widget.pressedScale
          : (ring && !reduceMotion ? 1.05 : 1),
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

    child = Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        if (mounted) setState(() => _focused = value);
      },
      onKeyEvent: _onKey,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.focusRadius),
          border: ring
              ? Border.all(color: Colors.white, width: 3)
              : null,
        ),
        child: child,
      ),
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

class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.focusRadius = 16,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final double focusRadius;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  final FocusNode _focus = FocusNode(debugLabel: 'Focusable');
  bool _focused = false;
  bool _holdFired = false;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onMode);
    _holdTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onMode(FocusHighlightMode mode) {
    if (mounted && _focused) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isOk = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!isOk || (widget.onTap == null && widget.onLongPress == null)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _holdFired = false;
      _holdTimer?.cancel();
      if (widget.onLongPress != null) {
        _holdTimer = Timer(const Duration(milliseconds: 520), () {
          _holdFired = true;
          widget.onLongPress?.call();
        });
      }
    } else if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      if (!_holdFired) widget.onTap?.call();
      _holdFired = false;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ring = _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        if (mounted) setState(() => _focused = value);
      },
      onKeyEvent: _onKey,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.focusRadius),
          border: ring ? Border.all(color: Colors.white, width: 3) : null,
        ),
        child: widget.child,
      ),
    );
  }
}
