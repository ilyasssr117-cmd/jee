import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../content_source.dart';
import '../touch.dart';

/// Shows the app-wide catalogue selector.
///
/// When [requiredChoice] is true the dialog cannot be dismissed until the
/// user confirms a source. This mode is used once on every cold app launch.
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
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => Stack(
      fit: StackFit.expand,
      children: [
        // Blur and gently dim the screen behind the compact selector.
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.34),
            ),
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
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
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
        elevation: 18,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: AppColors.outline),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose your content',
                  style: AppText.headline.copyWith(fontSize: 19, height: 1.2),
                ),
                const SizedBox(height: 5),
                Text(
                  'Choose an option to continue. You can change it later in Settings.',
                  style: AppText.caption.copyWith(fontSize: 11, height: 1.3),
                ),
                const SizedBox(height: 13),
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
                    const SizedBox(height: 7),
                ],
                const SizedBox(height: 13),
                Row(
                  children: [
                    if (!widget.requiredChoice) ...[
                      TextButton(
                        style: TextButton.styleFrom(
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
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () {
                        Haptics.play(Haptic.medium);
                        Navigator.of(context).pop(_selected);
                      },
                      child: const Text('Continue'),
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
    return Material(
      color: selected
          ? AppColors.accent.withValues(alpha: 0.10)
          : AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(Radii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.outline,
              width: selected ? 1.4 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_icon, color: AppColors.accentStrong, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      style: AppText.title.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color:
                    selected ? AppColors.accentStrong : AppColors.textTertiary,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
