import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, Colors, Divider;

import '../app_theme.dart';
import '../touch.dart';

/// One column of a wheel picker (like UIPickerView's component).
class WheelColumn {
  const WheelColumn({
    required this.labels,
    this.initialIndex = 0,
    this.title,
    this.flex = 1,
  });

  final List<String> labels;
  final int initialIndex;

  /// Optional small caption above the wheel (e.g. "Quality", "Speed").
  final String? title;
  final int flex;
}

/// Native iOS wheel picker presented as a bottom popup with a Cancel / Done
/// toolbar, magnifier, selection haptics and a blurred translucent surface.
///
/// Returns the selected index of every column, or `null` when cancelled.
Future<List<int>?> showWheelPicker(
  BuildContext context, {
  String? title,
  required List<WheelColumn> columns,
  bool dark = false,
}) {
  Haptics.play(Haptic.light);
  return showCupertinoModalPopup<List<int>>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (popupContext) => _WheelSheet(
      title: title,
      columns: columns,
      dark: dark,
    ),
  );
}

class _WheelSheet extends StatefulWidget {
  const _WheelSheet({
    required this.title,
    required this.columns,
    required this.dark,
  });

  final String? title;
  final List<WheelColumn> columns;
  final bool dark;

  @override
  State<_WheelSheet> createState() => _WheelSheetState();
}

class _WheelSheetState extends State<_WheelSheet> {
  late final List<int> _selected = <int>[
    for (final column in widget.columns)
      column.initialIndex.clamp(0, column.labels.length - 1).toInt(),
  ];
  late final List<FixedExtentScrollController> _controllers =
      <FixedExtentScrollController>[
    for (var i = 0; i < widget.columns.length; i++)
      FixedExtentScrollController(initialItem: _selected[i]),
  ];

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark || AppColors.palette.brightness == Brightness.dark;
    final surface = widget.dark ? OnDark.surface : AppColors.surface;
    final text = widget.dark ? OnDark.textPrimary : AppColors.textPrimary;
    final secondary =
        widget.dark ? OnDark.textSecondary : AppColors.textSecondary;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;

    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        primaryColor: AppColors.accent,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            color: surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Toolbar --------------------------------------------------
                SizedBox(
                  height: 50,
                  child: Row(
                    children: [
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(44, 44),
                        onPressed: () {
                          Haptics.play(Haptic.selection);
                          Navigator.of(context).pop();
                        },
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontSize: 17,
                            letterSpacing: -0.41,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.title ?? '',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.41,
                            color: text,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(44, 44),
                        onPressed: () {
                          Haptics.play(Haptic.medium);
                          Navigator.of(context).pop(List<int>.of(_selected));
                        },
                        child: const Text(
                          'Done',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.41,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: widget.dark ? OnDark.outline : AppColors.outline,
                ),
                // Wheels ---------------------------------------------------
                SizedBox(
                  height: 216,
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.columns.length; i++)
                        Expanded(
                          flex: widget.columns[i].flex,
                          child: Column(
                            children: [
                              if (widget.columns[i].title != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    widget.columns[i].title!.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.6,
                                      color: secondary,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: CupertinoPicker(
                                  scrollController: _controllers[i],
                                  itemExtent: 38,
                                  magnification: 1.06,
                                  squeeze: 1.15,
                                  diameterRatio: 1.25,
                                  useMagnifier: true,
                                  backgroundColor: Colors.transparent,
                                  selectionOverlay:
                                      CupertinoPickerDefaultSelectionOverlay(
                                    background: (widget.dark
                                            ? const Color(0xFFFFFFFF)
                                            : const Color(0xFF767680))
                                        .withValues(alpha: 0.12),
                                  ),
                                  onSelectedItemChanged: (index) {
                                    _selected[i] = index;
                                    // Same tick the system picker makes.
                                    Haptics.play(Haptic.selection);
                                  },
                                  children: [
                                    for (final label in widget.columns[i].labels)
                                      Center(
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          style: TextStyle(
                                            fontSize: 21,
                                            letterSpacing: -0.4,
                                            color: text,
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: bottom + 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of [showActionSheet].
class SheetAction<T> {
  const SheetAction({
    required this.label,
    required this.value,
    this.destructive = false,
    this.isDefault = false,
    this.icon,
  });

  final String label;
  final T value;
  final bool destructive;
  final bool isDefault;
  final IconData? icon;
}

/// Native iOS action sheet (UIAlertController, .actionSheet style).
Future<T?> showActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<SheetAction<T>> actions,
  String cancelLabel = 'Cancel',
}) {
  Haptics.play(Haptic.light);
  return showCupertinoModalPopup<T>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (sheetContext) => CupertinoActionSheet(
      title: title == null ? null : Text(title),
      message: message == null ? null : Text(message),
      actions: [
        for (final action in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: action.destructive,
            isDefaultAction: action.isDefault,
            onPressed: () {
              Haptics.play(
                action.destructive ? Haptic.medium : Haptic.selection,
              );
              Navigator.of(sheetContext).pop(action.value);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (action.icon != null) ...[
                  Icon(action.icon, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(action.label)),
              ],
            ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: Text(cancelLabel),
      ),
    ),
  );
}
