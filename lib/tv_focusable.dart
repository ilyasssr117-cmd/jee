import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// Keys that activate the focused control.
final Set<LogicalKeyboardKey> _activationKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
  LogicalKeyboardKey.space,
};

/// Shared remote-friendly focus wrapper for cards and controls.
///
/// * Activates on OK / Enter (key-down only; key repeat is swallowed so holding
///   the button can never push a route twice).
/// * Scales slightly while focused. The scale is paint-only, so it never moves
///   neighbouring widgets.
/// * Scrolls itself into view when focused, unless [scrollAlignment] is null
///   (used by widgets whose parent drives scrolling).
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.builder,
    required this.onTap,
    this.onFocus,
    this.focusNode,
    this.autofocus = false,
    this.scale = 1.05,
    this.scrollAlignment = 0.4,
    this.semanticLabel,
    this.focusOnHover = false,
    this.onLongPress,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback onTap;
  final VoidCallback? onFocus;
  final FocusNode? focusNode;
  final bool autofocus;
  final double scale;

  /// Where to place this widget in the viewport when it receives focus
  /// (0 = leading edge, 1 = trailing edge). Null disables auto-scroll.
  final double? scrollAlignment;
  final String? semanticLabel;

  /// Moves focus here when a real mouse pointer moves over the widget.
  final bool focusOnHover;

  /// Hold OK (or long-press). When set, a short press activates on release
  /// instead of on press, so the two can be told apart.
  final VoidCallback? onLongPress;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  bool _pressed = false;
  bool _longFired = false;

  void _handleFocusChange(bool focused) {
    if (!mounted) return;
    if (!focused) {
      _pressed = false;
      _longFired = false;
    }
    if (_focused != focused) setState(() => _focused = focused);
    if (!focused) return;

    widget.onFocus?.call();

    final alignment = widget.scrollAlignment;
    if (alignment == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focused || Scrollable.maybeOf(context) == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: alignment,
        duration: Motion.scroll,
        curve: Motion.curve,
      );
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_activationKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (widget.onLongPress != null) {
      if (event is KeyDownEvent) {
        _pressed = true;
        _longFired = false;
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        // The first auto-repeat of a held button is the long press.
        if (_pressed && !_longFired) {
          _longFired = true;
          widget.onLongPress!();
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        final tap = _pressed && !_longFired;
        _pressed = false;
        _longFired = false;
        if (tap) widget.onTap();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    // Swallow auto-repeat so a held OK button doesn't fire repeatedly.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Widget child = AnimatedScale(
      scale: _focused ? widget.scale : 1,
      duration: Motion.focus,
      curve: Motion.curve,
      child: widget.builder(context, _focused),
    );

    if (widget.semanticLabel != null) {
      child = ExcludeSemantics(child: child);
    }

    return Semantics(
      button: true,
      focusable: true,
      focused: _focused,
      label: widget.semanticLabel,
      onTap: widget.onTap,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _handleFocusChange,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: widget.focusOnHover
              ? Builder(
                  builder: (context) => MouseRegion(
                    // onHover (not onEnter): content scrolling under a still
                    // pointer must never steal D-pad focus.
                    onHover: (_) {
                      if (!_focused) Focus.of(context).requestFocus();
                    },
                    child: child,
                  ),
                )
              : child,
        ),
      ),
    );
  }
}

/// Traversal policy for the whole app.
///
/// Directional (D-pad) navigation is geometric. Scrolling is handled by
/// [TvFocusable], so the policy's own scroll-into-view is disabled to stop two
/// competing scroll animations from fighting each other.
FocusTraversalPolicy buildTvTraversalPolicy() {
  return ReadingOrderTraversalPolicy(
    requestFocusCallback: (
      FocusNode node, {
      ScrollPositionAlignmentPolicy? alignmentPolicy,
      double? alignment,
      Duration? duration,
      Curve? curve,
    }) {
      node.requestFocus();
    },
  );
}
