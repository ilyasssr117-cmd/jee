import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../content_source.dart';
import '../touch.dart';
import '../platform_ui.dart';

Future<ContentSource?> showContentSourcePicker(
  BuildContext context, {
  required ContentSource initialSource,
  bool requiredChoice = false,
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
  });

  final ContentSource initialSource;
  final bool requiredChoice;

  @override
  State<_ContentSourcePickerDialog> createState() =>
      _ContentSourcePickerDialogState();
}

class _ContentSourcePickerDialogState
    extends State<_ContentSourcePickerDialog> {
  late ContentSource _selected = widget.initialSource;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    return PopScope(
      canPop: !widget.requiredChoice,
      child: Dialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 20,
        insetPadding: EdgeInsets.symmetric(
          horizontal: tv ? 72 : 28,
          vertical: tv ? 42 : 20,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tv ? 30 : 24),
          side: BorderSide(color: AppColors.outline),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tv ? 560 : 332),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tv ? 32 : 18,
              tv ? 30 : 19,
              tv ? 32 : 18,
              tv ? 28 : 16,
            ),
            child: FocusTraversalGroup(
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
                        size: tv ? 24 : 19,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        widget.requiredChoice
                            ? 'Choose your content'
                            : 'Content source',
                        style: AppText.headline.copyWith(
                          fontSize: tv ? 27 : 18,
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
                      fontSize: tv ? 16 : 12,
                      height: 1.35,
                    ),
                  ),
                ),
                SizedBox(height: tv ? 24 : 17),
                for (final source in ContentSource.values) ...[
                  _SourceOption(
                    source: source,
                    selected: source == _selected,
                    tvMode: tv,
                    autofocus: tv && source == _selected,
                    onTap: () {
                      Haptics.play(Haptic.selection);
                      setState(() => _selected = source);
                    },
                  ),
                  if (source != ContentSource.values.last)
                    SizedBox(height: tv ? 12 : 8),
                ],
                SizedBox(height: tv ? 24 : 17),
                Row(
                  children: [
                    if (!widget.requiredChoice) ...[
                      TextButton(
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
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accentStrong,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: Size(tv ? 164 : 104, tv ? 56 : 40),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                        textStyle: TextStyle(
                          fontSize: tv ? 17 : 13,
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
    required this.onTap,
    required this.tvMode,
    required this.autofocus,
  });

  final ContentSource source;
  final bool selected;
  final VoidCallback onTap;
  final bool tvMode;
  final bool autofocus;

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
    final isSelect = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (isSelect && event is KeyDownEvent) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    if (isSelect && (event is KeyUpEvent || event is KeyRepeatEvent)) {
      return KeyEventResult.handled;
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
    final source = widget.source;
    final tv = widget.tvMode;
    final borderColor = _focused || selected
        ? AppColors.accentStrong
        : AppColors.outline;

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        if (mounted) setState(() => _focused = focused);
      },
      onKeyEvent: _onKey,
      child: Semantics(
        button: true,
        selected: selected,
        label: source.label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.09)
                : AppColors.surfaceHigh.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(tv ? 18 : 15),
            border: Border.all(
              color: borderColor,
              width: _focused ? 2.5 : (selected ? 1.35 : 0.8),
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: AppColors.accentStrong.withValues(alpha: 0.22),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(tv ? 18 : 15),
              onTap: widget.onTap,
              child: SizedBox(
                height: tv ? 68 : 52,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: tv ? 20 : 12),
                  child: Row(
                    children: [
                      Icon(
                        _icon,
                        color: selected
                            ? AppColors.accentForeground
                            : AppColors.textTertiary,
                        size: tv ? 26 : 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          source.label,
                          style: AppText.title.copyWith(
                            fontSize: tv ? 19 : 14,
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
                          size: tv ? 24 : 19,
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
