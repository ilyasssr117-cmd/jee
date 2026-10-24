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

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  void _handleFocusChange(bool focused) {
    if (!mounted) return;
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
          child: child,
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
