import 'dart:async';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'bottom_bar.dart';
import 'ios_sheets.dart';

/// Destructive confirmations use the native iOS action sheet that slides up
/// from the bottom (UIAlertController `.actionSheet`), with a separated
/// Cancel button — exactly how Photos / Files / Mail confirm deletes.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final result = await showActionSheet<bool>(
    context,
    title: title,
    message: message,
    actions: [
      SheetAction<bool>(
        label: confirmLabel,
        value: true,
        destructive: destructive,
        isDefault: !destructive,
      ),
    ],
  );
  return result ?? false;
}

OverlayEntry? _toastEntry;
Timer? _toastTimer;

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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xB82C2C2E),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: const Color(0x1FFFFFFF),
                      width: 0.5,
                    ),
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
        ),
      ),
    );
  }
}

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
