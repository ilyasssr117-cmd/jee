import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, showCupertinoDialog;
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../touch.dart';
import 'bottom_bar.dart';

/// Native iOS confirmation alert. Returns true when the viewer confirms.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  Haptics.play(Haptic.light);
  final result = await showCupertinoDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: destructive,
          isDefaultAction: !destructive,
          onPressed: () {
            Haptics.play(Haptic.medium);
            Navigator.of(dialogContext).pop(true);
          },
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

OverlayEntry? _toastEntry;
Timer? _toastTimer;

/// Small pill that fades in, waits, and fades out (no snack bar). It floats
/// above the tab bar, or near the screen edge when [aboveBar] is false (pages
/// without the bar).
void showToast(BuildContext context, String message, {bool aboveBar = true}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _toastTimer?.cancel();
  _toastEntry?.remove();

  const showFor = Duration(milliseconds: 2400);
  final bottom = aboveBar
      ? kBottomBarHeight + context.safe.bottom + 6
      : context.safe.bottom + Gaps.lg;

  final entry = OverlayEntry(
    builder: (_) => _ToastView(message: message, bottom: bottom, showFor: showFor),
  );
  overlay.insert(entry);
  _toastEntry = entry;
  _toastTimer = Timer(showFor + const Duration(milliseconds: 400), () {
    entry.remove();
    if (_toastEntry == entry) _toastEntry = null;
  });
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.message,
    required this.bottom,
    required this.showFor,
  });

  final String message;
  final double bottom;
  final Duration showFor;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 320),
  )..forward();

  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _hide = Timer(widget.showFor, () {
      if (mounted) _fade.reverse();
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: Gaps.xl,
      right: Gaps.xl,
      bottom: widget.bottom,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: _fade, curve: Curves.easeInOut),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.25),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: _fade, curve: Curves.easeOut)),
              child: Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xEB1C1F2A),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(color: Color(0x4D000000), blurRadius: 14),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
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

/// "12.3 MB" style size.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(bytes >= 100 * mb ? 0 : 1)} MB';
  }
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}
