import 'package:flutter/material.dart';

import '../app_theme.dart';

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
        final canExpand = constraints.maxWidth.isFinite &&
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
              physics: const ClampingScrollPhysics(),
              child: text,
            ),
          );
        } else if (widget.ignoreTextPointer) {
          text = IgnorePointer(child: text);
        }

        if (!canExpand) {
          return text;
        }

        final toggle = widget.toggleStyle ??
            widget.style.copyWith(
              fontSize: (widget.style.fontSize ?? 14) - 1,
              fontWeight: FontWeight.w700,
              color: AppColors.accent,
            );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: Motion.quick,
              curve: Curves.easeOutCubic,
              alignment: AlignmentDirectional.topStart,
              child: text,
            ),
            Semantics(
              button: true,
              label: _expanded ? 'Show less' : 'Show full title',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 36),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: 28),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: 1,
                      child: Text(_expanded ? 'less' : 'more', style: toggle),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
