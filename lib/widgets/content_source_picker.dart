import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../content_source.dart';
import '../touch.dart';

Future<ContentSource?> showContentSourcePicker(
  BuildContext context, {
  required ContentSource initialSource,
  bool requiredChoice = false,
  bool tvMode = false,
}) {
  return showGeneralDialog<ContentSource>(
    context: context,
    barrierDismissible: !requiredChoice,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 230),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => Stack(
      fit: StackFit.expand,
      children: [
        if (requiredChoice)
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.38),
              ),
            ),
          )
        else
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.20),
            ),
          ),
        SafeArea(
          child: Center(
            child: _ContentSourcePickerDialog(
              initialSource: initialSource,
              requiredChoice: requiredChoice,
              tvMode: tvMode,
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _ContentSourcePickerDialog extends StatefulWidget {
  const _ContentSourcePickerDialog({
    required this.initialSource,
    required this.requiredChoice,
    required this.tvMode,
  });

  final ContentSource initialSource;
  final bool requiredChoice;
  final bool tvMode;

  @override
  State<_ContentSourcePickerDialog> createState() =>
      _ContentSourcePickerDialogState();
}

class _ContentSourcePickerDialogState
    extends State<_ContentSourcePickerDialog> {
  late ContentSource _selected = widget.initialSource;
  final FocusNode _cancelFocusNode = FocusNode(debugLabel: 'Cancel source');
  final FocusNode _saveFocusNode = FocusNode(debugLabel: 'Save source');

  @override
  void dispose() {
    _cancelFocusNode.dispose();
    _saveFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // TV layout only for actual televisions (fix 5.5): width alone no
    // longer classifies tablets/foldables/desktop windows as TVs.
    final tvLayout = widget.tvMode;
    return PopScope(
      canPop: !widget.requiredChoice,
      child: Dialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 20,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: AppColors.outline),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: tvLayout ? 560 : 332,
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: SingleChildScrollView(
          child: Padding(
            padding: tvLayout
                ? const EdgeInsets.fromLTRB(26, 24, 26, 22)
                : const EdgeInsets.fromLTRB(18, 19, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.explore_outlined,
                        color: AppColors.accentForeground,
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        widget.requiredChoice
                            ? 'Choose your content'
                            : 'Content source',
                        style: AppText.headline.copyWith(
                          fontSize: tvLayout ? 24 : 18,
                          letterSpacing: -0.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.only(left: 47),
                  child: Text(
                    widget.requiredChoice
                        ? 'Select an option to start browsing.'
                        : 'Choose which catalogue you want to browse.',
                    style: AppText.caption.copyWith(
                      fontSize: tvLayout ? 16 : 12,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 17),
                for (final source in ContentSource.values) ...[
                  _SourceOption(
                    source: source,
                    selected: source == _selected,
                    tvLayout: tvLayout,
                    onDownFromLast: source == ContentSource.values.last
                        ? () => _saveFocusNode.requestFocus()
                        : null,
                    onTap: () {
                      Haptics.play(Haptic.selection);
                      setState(() => _selected = source);
                    },
                  ),
                  if (source != ContentSource.values.last)
                    SizedBox(height: tvLayout ? 12 : 8),
                ],
                const SizedBox(height: 17),
                Row(
                  children: [
                    if (!widget.requiredChoice) ...[
                      TextButton(
                        focusNode: _cancelFocusNode,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                    ] else
                      const Spacer(),
                    FilledButton(
                      focusNode: _saveFocusNode,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accentStrong,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: tvLayout
                            ? const Size(132, 54)
                            : const Size(104, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () {
                        Haptics.play(Haptic.medium);
                        Navigator.of(context).pop(_selected);
                      },
                      child: Text(widget.requiredChoice ? 'Continue' : 'Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

class _SourceOption extends StatefulWidget {
  const _SourceOption({
    required this.source,
    required this.selected,
    required this.tvLayout,
    this.onDownFromLast,
    required this.onTap,
  });

  final ContentSource source;
  final bool selected;
  final bool tvLayout;
  final VoidCallback? onDownFromLast;
  final VoidCallback onTap;

  @override
  State<_SourceOption> createState() => _SourceOptionState();
}

class _SourceOptionState extends State<_SourceOption> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Content source option');
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown &&
        widget.onDownFromLast != null &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      widget.onDownFromLast!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent) widget.onTap();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final direction = switch (key) {
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

  IconData get _icon => switch (widget.source) {
        ContentSource.fetish => Icons.favorite_border_rounded,
        ContentSource.straight => Icons.play_circle_outline_rounded,
        ContentSource.trans => Icons.people_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final borderColor = _focused
        ? Colors.white
        : selected
            ? AppColors.accentStrong
            : AppColors.outline;

    return Semantics(
      button: true,
      selected: selected,
      label: widget.source.label,
      child: Focus(
        focusNode: _focusNode,
        autofocus: selected,
        onKeyEvent: _onKey,
        onFocusChange: (value) {
          if (mounted && value != _focused) setState(() => _focused = value);
        },
        child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.09)
              : AppColors.surfaceHigh.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: borderColor,
            width: _focused ? 3 : selected ? 2 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            focusColor: AppColors.accentStrong.withValues(alpha: 0.22),
            canRequestFocus: false,
            onTap: widget.onTap,
            child: SizedBox(
              height: widget.tvLayout ? 68 : 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      _icon,
                      color: selected
                          ? AppColors.accentForeground
                          : AppColors.textTertiary,
                      size: widget.tvLayout ? 25 : 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.source.label,
                        style: AppText.title.copyWith(
                          fontSize: widget.tvLayout ? 19 : 14,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 140),
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        key: ValueKey<bool>(selected),
                        color: selected
                            ? AppColors.accentForeground
                            : AppColors.textTertiary.withValues(alpha: 0.7),
                        size: widget.tvLayout ? 24 : 19,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
