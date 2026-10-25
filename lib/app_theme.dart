import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_settings.dart';

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

abstract final class AppColors {
  static bool get _dark => AppSettings.instance.isDark;
  static Color get background => _dark ? const Color(0xFF0B0D12) : const Color(0xFFF5F6FA);
  static Color get surface => _dark ? const Color(0xFF151923) : const Color(0xFFFFFFFF);
  static Color get surfaceHigh => _dark ? const Color(0xFF1E2333) : const Color(0xFFEEF0F6);
  static Color get outline => _dark ? const Color(0x1FFFFFFF) : const Color(0x180D1424);
  static Color get accent => _dark ? const Color(0xFF8B7CFF) : const Color(0xFF6556D9);
  static Color get accentStrong => _dark ? const Color(0xFF6C5CE7) : const Color(0xFF5948C6);
  static Color get textPrimary => _dark ? const Color(0xFFFFFFFF) : const Color(0xFF171923);
  static Color get textSecondary => _dark ? const Color(0xFFB7BDCB) : const Color(0xFF535C70);
  static Color get textTertiary => _dark ? const Color(0xFF8E96A8) : const Color(0xFF707A8D);
  static Color get error => _dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E);
  static Color get blue => _dark ? const Color(0xFF4C93FF) : const Color(0xFF2665D8);
  static Color get blueSoft => _dark ? const Color(0xFF1B2B4D) : const Color(0xFFE3EBFF);
  static Color get star => const Color(0xFFFFC857);
}

// ---------------------------------------------------------------------------
// Spacing, radii, motion (real phone points)
// ---------------------------------------------------------------------------

abstract final class Gaps {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class Radii {
  static const double card = 12;
  static const double button = 10;
  static const double field = 12;
  static const double pill = 999;
}

abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration fade = Duration(milliseconds: 320);
  static const Duration scroll = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
}

// ---------------------------------------------------------------------------
// Responsive helpers
// ---------------------------------------------------------------------------

extension UiScale on BuildContext {
  /// iPhone / Android phone (short side under 600 logical px).
  bool get isPhone => MediaQuery.sizeOf(this).shortestSide < 600;

  /// ~1.0 on an iPhone; slightly larger on tablets.
  double get uiScale =>
      (MediaQuery.sizeOf(this).shortestSide / 390).clamp(0.9, 1.25).toDouble();

  double s(double value) => value * uiScale;

  /// Horizontal page margin.
  double get hMargin => isPhone ? 16 : 24;

  /// Notch / home-indicator insets.
  EdgeInsets get safe => MediaQuery.viewPaddingOf(this);
}

/// Columns of every video grid.
int videoGridColumns(BuildContext context) => context.isPhone ? 2 : 3;

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------

abstract final class AppText {
  static TextStyle get display => TextStyle(
    fontSize: 26, height: 1.15, fontWeight: FontWeight.w800,
    letterSpacing: -0.4, color: AppColors.textPrimary,
  );
  static TextStyle get headline => TextStyle(
    fontSize: 20, height: 1.2, fontWeight: FontWeight.w700,
    letterSpacing: -0.2, color: AppColors.textPrimary,
  );
  static TextStyle get title => TextStyle(
    fontSize: 16, height: 1.25, fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static TextStyle get cardTitle => TextStyle(
    fontSize: 13.5, height: 1.25, fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static TextStyle get body => TextStyle(
    fontSize: 14, height: 1.4, fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static TextStyle get label => TextStyle(
    fontSize: 14, height: 1.2, fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static TextStyle get caption => TextStyle(
    fontSize: 12, height: 1.3, fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );
  static TextStyle get overline => TextStyle(
    fontSize: 11, height: 1.2, fontWeight: FontWeight.w700,
    letterSpacing: 1.4, color: AppColors.accent,
  );
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

ThemeData buildAppTheme({bool dark = true}) {
  final brightness = dark ? Brightness.dark : Brightness.light;
  final background = dark ? const Color(0xFF0B0D12) : const Color(0xFFF5F6FA);
  final surface = dark ? const Color(0xFF151923) : const Color(0xFFFFFFFF);
  final surfaceHigh = dark ? const Color(0xFF1E2333) : const Color(0xFFEEF0F6);
  final accent = dark ? const Color(0xFF8B7CFF) : const Color(0xFF6556D9);
  final textColor = dark ? const Color(0xFFFFFFFF) : const Color(0xFF171923);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: surface,
    ),
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: textColor,
      displayColor: textColor,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surfaceHigh,
      contentTextStyle: TextStyle(
        fontSize: 14,
        color: textColor,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.button),
      ),
    ),
    // Native iOS push + edge-swipe back gesture on every platform.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        for (final platform in TargetPlatform.values)
          platform: const CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// Plain cross-fade route (used for the player: black fades into video).
class FadePageRoute<T> extends PageRouteBuilder<T> {
  FadePageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, _, __) => builder(context),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
              reverseCurve: Curves.easeIn,
            ),
            child: child,
          ),
        );
}

/// iOS-style bouncing scroll, no glow.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
