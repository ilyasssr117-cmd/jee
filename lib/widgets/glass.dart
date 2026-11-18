import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../app_theme.dart';

abstract final class Glass {
  static bool enabled = true;

  static bool isOpaque(BuildContext context) =>
      !enabled ||
      defaultTargetPlatform == TargetPlatform.windows ||
      MediaQuery.highContrastOf(context);
}

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.sigma = 20,
    this.padding,
    this.tint,
    this.shadow = true,
    this.blur = true,
  });

  final Widget child;
  final double borderRadius;

  final double sigma;
  final EdgeInsetsGeometry? padding;

  final Color? tint;
  final bool shadow;

  final bool blur;

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.palette.brightness == Brightness.dark;
    final opaque = Glass.isOpaque(context);
    final radius = BorderRadius.circular(borderRadius);

    final Color fill = opaque
        ? (dark ? AppColors.surfaceHigh : AppColors.surface)
        : (tint ?? (dark ? const Color(0x2EFFFFFF) : const Color(0xB8FFFFFF)));

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        gradient: opaque
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: dark ? 0.14 : 0.45),
                  Colors.white.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.7],
              ),
      ),
      child: CustomPaint(
        foregroundPainter: _RimPainter(
          radius: borderRadius,
          dark: dark,
          opaque: opaque,
          outline: AppColors.outline,
        ),
        child:
            padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );

    Widget clipped = ClipRRect(
      borderRadius: radius,
      child: (blur && !opaque)
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
              child: content,
            )
          : content,
    );

    if (shadow && !opaque) {
      clipped = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.32 : 0.14),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: clipped,
      );
    }

    return RepaintBoundary(child: clipped);
  }
}

class _RimPainter extends CustomPainter {
  const _RimPainter({
    required this.radius,
    required this.dark,
    required this.opaque,
    required this.outline,
  });

  final double radius;
  final bool dark;
  final bool opaque;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular((radius - 0.5).clamp(0.0, double.infinity).toDouble()),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (opaque) {
      paint.color = outline;
    } else {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: dark ? 0.55 : 0.95),
          Colors.white.withValues(alpha: dark ? 0.06 : 0.25),
          Colors.white.withValues(alpha: dark ? 0.28 : 0.70),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect);
    }
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _RimPainter old) =>
      radius != old.radius ||
      dark != old.dark ||
      opaque != old.opaque ||
      outline != old.outline;
}

class SoftBackdrop extends StatelessWidget {
  const SoftBackdrop({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
  });

  final ui.ImageFilter filter;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || Glass.isOpaque(context)) return child;
    return BackdropFilter(filter: filter, child: child);
  }
}
