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
  return showDialog<ContentSource>(
    context: context,
    barrierDismissible: !requiredChoice,
    builder: (dialogContext) => _ContentSourcePickerDialog(
      initialSource: initialSource,
      requiredChoice: requiredChoice,
    ),
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
        insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.large),
          side: BorderSide(color: AppColors.outline),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Choose your content', style: AppText.headline),
                const SizedBox(height: 7),
                Text(
                  'Choose an option to continue. You can change it later in Settings.',
                  style: AppText.caption.copyWith(height: 1.4),
                ),
                const SizedBox(height: 18),
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
                    const SizedBox(height: 9),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    if (!widget.requiredChoice) ...[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                    ] else
                      const Spacer(),
                    FilledButton(
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
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
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
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_icon, color: AppColors.accentStrong, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      style: AppText.title.copyWith(
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
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
