import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

const Color appBackground = Color(0xFF0B0D12);
const Color panelColor = Color(0xFF151923);
const Color accentColor = Color(0xFF8B7CFF);

abstract final class AppColors {
  static const Color background = appBackground;
  static const Color surface = panelColor;
  static const Color surfaceHigh = Color(0xFF1E2333);
  static const Color outline = Color(0x1FFFFFFF);

  /// Brand accent for text / thin lines on dark surfaces.
  static const Color accent = accentColor;

  /// Darker accent used for filled buttons so white labels stay legible.
  static const Color accentStrong = Color(0xFF6C5CE7);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB7BDCB);
  static const Color textTertiary = Color(0xFF8E96A8);

  static const Color error = Color(0xFFFF8A80);

  /// Blue used for the active tab and the search cursor.
  static const Color blue = Color(0xFF4C93FF);
  static const Color blueSoft = Color(0xFF1B2B4D);

  /// Active favourite star.
  static const Color star = Color(0xFFFFC857);
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
  static const TextStyle display = TextStyle(
    fontSize: 26,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.4,
    color: AppColors.textPrimary,
  );

  static const TextStyle headline = TextStyle(
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  static const TextStyle title = TextStyle(
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle cardTitle = TextStyle(
    fontSize: 13.5,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  static const TextStyle label = TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );

  static const TextStyle overline = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
    color: AppColors.accent,
  );
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    ),
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: AppText.body.copyWith(color: AppColors.textPrimary),
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
