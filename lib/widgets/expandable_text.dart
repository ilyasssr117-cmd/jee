import 'package:flutter/material.dart';

import '../app_theme.dart';

/// A title that is clamped to [collapsedLines] and ends in an ellipsis ("…").
/// Tap the text to read all of it, tap it again to collapse it. There is no
/// separate "more" / "less" word.
class ExpandableText extends StatefulWidget {
  const ExpandableText(
    this.text, {
    super.key,
    required this.style,
    this.collapsedLines = 2,
    this.toggleStyle,
    this.maxExpandedHeight,
    this.ignoreTextPointer = false,
  });

  final String text;
  final TextStyle style;
  final int collapsedLines;

  /// Kept for source compatibility; the toggle word no longer exists.
  final TextStyle? toggleStyle;

  final double? maxExpandedHeight;

  final bool ignoreTextPointer;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ExpandableText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && _expanded) _expanded = false;
  }

  bool _overflows(BuildContext context, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: widget.collapsedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final result = painter.didExceedMaxLines;
    painter.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canExpand =
            constraints.maxWidth.isFinite &&
            _overflows(context, constraints.maxWidth);

        Widget text = Text(
          widget.text,
          maxLines: _expanded || !canExpand ? null : widget.collapsedLines,
          overflow: _expanded || !canExpand
              ? TextOverflow.visible
              : TextOverflow.ellipsis,
          style: widget.style,
        );

        if (_expanded && widget.maxExpandedHeight != null) {
          text = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxExpandedHeight!),
            child: SingleChildScrollView(
              physics: nativeScrollPhysics(context),
              child: text,
            ),
          );
        }

        if (!canExpand) {
          return widget.ignoreTextPointer ? IgnorePointer(child: text) : text;
        }

        return Semantics(
          button: true,
          label: _expanded ? 'Collapse title' : 'Show full title',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: AnimatedSize(
              duration: Motion.quick,
              curve: Curves.easeOutCubic,
              alignment: AlignmentDirectional.topStart,
              child: text,
            ),
          ),
        );
      },
    );
  }
}
