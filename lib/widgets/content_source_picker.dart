import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../content_source.dart';
import '../touch.dart';

/// Shows the app-wide catalogue selector.
///
/// The launch flow ([requiredChoice] == true) uses a blurred backdrop. The
/// Settings flow keeps the page sharp and only adds a light dim overlay.
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
          constraints: const BoxConstraints(maxWidth: 332),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 19, 18, 16),
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
                          fontSize: 18,
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
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 17),
                for (final source in ContentSource.values) ...[
                  _SourceOption(
                    source: source,
                    selected: source == _selected,
                    onTap: () {
                      Haptics.play(Haptic.selection);
                      setState(() => _selected = source);
                    },
                  ),
                  if (source != ContentSource.values.last)
                    const SizedBox(height: 8),
                ],
                const SizedBox(height: 17),
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
                        minimumSize: const Size(104, 40),
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
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final ContentSource source;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (source) {
        ContentSource.fetish => Icons.favorite_border_rounded,
        ContentSource.straight => Icons.play_circle_outline_rounded,
        ContentSource.trans => Icons.people_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.accentStrong : AppColors.outline;

    return Semantics(
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
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: borderColor,
            width: selected ? 1.35 : 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: onTap,
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      _icon,
                      color: selected
                          ? AppColors.accentForeground
                          : AppColors.textTertiary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        source.label,
                        style: AppText.title.copyWith(
                          fontSize: 14,
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
                        size: 19,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
